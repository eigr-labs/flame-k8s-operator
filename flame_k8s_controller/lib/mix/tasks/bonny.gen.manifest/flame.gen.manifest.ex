defmodule Mix.Tasks.Flame.Gen.Manifest do
  use Mix.Task

  alias Bonny.Mix.Operator
  alias FlameK8sController.K8sConn
  alias Mix.Tasks.Bonny.Gen.Manifest.FlameK8sControllerCustomizer

  import YamlElixir.Sigil

  @default_opts [namespace: "flame"]
  @switches [namespace: :string, image: :string, out: :string]
  @aliases [n: :namespace, i: :image, o: :out]

  @shortdoc "Generate Kubernetes YAML manifest for this operator"

  @spec run(list()) :: :ok
  def run(args) do
    Mix.Task.run("compile")

    {opts, _, _} =
      Mix.Bonny.parse_args(args, @default_opts, switches: @switches, aliases: @aliases)

    do_run(Mix.env(), opts)
  end

  @spec do_run(atom(), Keyword.t()) :: :ok
  def do_run(:prod, opts) do
    out = Keyword.fetch!(opts, :out)

    generate_manifest(:prod, opts)
    |> Ymlr.documents!()
    |> YamlElixir.read_all_from_string!()
    |> Enum.map(&FlameK8sControllerCustomizer.override/1)
    |> render(out)
  end

  def do_run(env, opts) when env in [:dev, :test] do
    cluster_name = "flame-#{env}"

    Application.ensure_all_started(:k8s)
    ensure_cluster(cluster_name, "./test/integration/kubeconfig-#{env}.yaml")
    conn = K8sConn.get!(env)
    ensure_namespace(conn, Keyword.fetch!(opts, :namespace))

    operations =
      generate_manifest(env, opts)
      |> Ymlr.documents!()
      |> YamlElixir.read_all_from_string!()
      |> Enum.map(&K8s.Client.apply/1)

    errors =
      conn
      |> K8s.Client.async(operations)
      |> Enum.reject(&match?({:ok, _}, &1))

    if errors == [] do
      Mix.Shell.IO.info("Manifest applied to cluster #{cluster_name}")
    else
      Mix.Shell.IO.error("Error occurred when applying manifests to cluster:")
      dbg(errors)
    end

    :ok
  end

  @spec render(list(map()), binary()) :: :ok
  defp render(documents, out) do
    if File.dir?(out) do
      documents
      |> Ymlr.documents!()
      |> YamlElixir.read_all_from_string!()
      |> Enum.map(fn
        %{"kind" => "CustomResourceDefinition"} = resource ->
          {"#{resource["spec"]["names"]["singular"]}.crd.yaml", resource}

        resource ->
          {"#{String.downcase(resource["kind"])}.yaml", resource}
      end)
      |> Enum.each(fn {filename, resource} ->
        Mix.Bonny.render(Ymlr.document!(resource), Path.join(out, filename))
      end)
    else
      documents
      |> Ymlr.documents!()
      |> Mix.Bonny.render(out)
    end

    :ok
  end

  @spec ensure_cluster(cluster_name :: binary(), kubeconfig_path :: binary()) :: :ok
  defp ensure_cluster(cluster_name, kubeconfig_path) do
    {clusters, 0} = System.cmd("kind", ~w(get clusters))

    if cluster_name not in String.split(clusters, "\n", trim: true) do
      Mix.Shell.IO.info("Creating kind cluster #{cluster_name}")

      0 =
        Mix.Shell.IO.cmd(
          "kind create cluster --name #{cluster_name} --config ./test/integration/kind-cluster.yml"
        )
    end

    if not File.exists?(kubeconfig_path) do
      Mix.Shell.IO.info("Generating kubeconfig file: #{kubeconfig_path}")

      0 =
        Mix.Shell.IO.cmd(
          ~s(kind export kubeconfig --kubeconfig "#{kubeconfig_path}" --name "#{cluster_name}")
        )
    end

    :ok
  end

  @spec ensure_namespace(K8s.Conn.t(), binary()) :: :ok
  defp ensure_namespace(conn, namespace) do
    {:ok, _} =
      K8s.Client.apply(~y"""
      apiVersion: v1
      kind: Namespace
      metadata:
        name: #{namespace}
      """)
      |> K8s.Client.put_conn(conn)
      |> K8s.Client.run()

    :ok
  end

  @spec generate_manifest(atom(), Keyword.t()) :: list(map())
  defp generate_manifest(:prod, opts) do
    image = Keyword.fetch!(opts, :image)
    namespace = Keyword.fetch!(opts, :namespace)

    [
      Operator.deployment(image, namespace),
      ns_manifest(namespace),
      svc_manifest(namespace),
      webhook_config_manifest(namespace)
      | generate_manifest(:dev, opts)
    ]
  end

  defp generate_manifest(_, opts) do
    namespace = Keyword.fetch!(opts, :namespace)
    operators = Operator.find_operators()

    Operator.crds(operators) ++
      [
        Operator.cluster_role(operators),
        Operator.service_account(namespace),
        Operator.cluster_role_binding(namespace),
        default_flame_pool(namespace),
        kustomize(namespace)
      ]
  end

  @spec ns_manifest(namespace :: binary()) :: map()
  def ns_manifest(namespace) do
    ~y"""
    apiVersion: v1
    kind: Namespace
    metadata:
      name: #{namespace}
    """
  end

  @spec svc_manifest(namespace :: binary()) :: map()
  def svc_manifest(namespace) do
    ~y"""
    apiVersion: v1
    kind: Service
    metadata:
      name: flame-controller
      namespace: #{namespace}
      labels:
        k8s-app: flame-controller
    spec:
      ports:
      - name: webhooks
        port: 443
        targetPort: webhooks
        protocol: TCP
      selector:
        k8s-app: flame-controller
    """
  end

  @spec webhook_config_manifest(namespace :: binary()) :: map()
  defp webhook_config_manifest(namespace) do
    ~y"""
    apiVersion: admissionregistration.k8s.io/v1
    kind: MutatingWebhookConfiguration
    metadata:
      name: "flame-k8s"
    webhooks:
      - name: "flame-k8s.flame.org"
        admissionReviewVersions: ["v1"]
        matchPolicy: Equivalent
        rules:
          - operations: ['CREATE', 'UPDATE']
            apiGroups: ['apps']
            apiVersions: ['v1']
            resources:
              - deployments
              - statefulsets
        failurePolicy: 'Ignore' # Fail-open (optional)
        clientConfig:
          service:
            namespace: #{namespace}
            name: flame-controller
            path: /admission-review/mutating
            port: 443
    """
  end

  @spec default_flame_pool(namespace :: binary()) :: map()
  defp default_flame_pool(namespace) do
    ~y"""
    apiVersion: flame.org/v1
    kind: FlamePool
    metadata:
      name: default-pool
      namespace: #{namespace}
    spec:
      podTemplate:
        spec:
          containers:
            - env:
              - name: PHX_SERVER
                value: "false"
              - name: MIX_ENV
                value: prod
              - name: POD_NAME
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.name
              - name: POD_NAMESPACE
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.namespace
              - name: POD_IP
                valueFrom:
                  fieldRef:
                    fieldPath: status.podIP
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
    """
  end

  @spec kustomize(namespace :: binary()) :: map()
  defp kustomize(_namespace) do
    ~y"""
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - namespace.yaml
      - serviceaccount.yaml
      - clusterrole.yaml
      - clusterrolebinding.yaml
      - flamepool.crd.yaml
      - flamerunner.crd.yaml
      - service.yaml
      - deployment.yaml
      - mutatingwebhookconfiguration.yaml
      - flamepool.yaml
    """
  end
end
