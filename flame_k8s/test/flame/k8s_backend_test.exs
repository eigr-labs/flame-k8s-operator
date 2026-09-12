defmodule FLAME.K8sBackendTest do
  use ExUnit.Case, async: true

  alias FLAME.K8sBackend

  describe "remaining_connect_window_ms/2" do
    test "clamps negative values to zero" do
      assert K8sBackend.remaining_connect_window_ms(100, 120) == 0
    end

    test "returns remaining milliseconds when still positive" do
      assert K8sBackend.remaining_connect_window_ms(1_000, 320) == 680
    end
  end

  describe "resolve_kubeconfig_path/0" do
    test "uses first path from KUBECONFIG list" do
      previous = System.get_env("KUBECONFIG")
      first = Path.join(System.tmp_dir!(), "kube-a")
      second = Path.join(System.tmp_dir!(), "kube-b")

      System.put_env("KUBECONFIG", "#{first}:#{second}")

      on_exit(fn ->
        restore_env("KUBECONFIG", previous)
      end)

      assert K8sBackend.resolve_kubeconfig_path() == first
    end

    test "falls back to default kubeconfig when KUBECONFIG is unset" do
      previous = System.get_env("KUBECONFIG")
      System.delete_env("KUBECONFIG")

      on_exit(fn ->
        restore_env("KUBECONFIG", previous)
      end)

      assert K8sBackend.resolve_kubeconfig_path() == Path.expand("~/.kube/config")
    end
  end

  describe "sanitize_init_opts/1" do
    test "drops unrelated options and keeps backend settings" do
      assert [boot_timeout: 1_234, log: :debug] =
               K8sBackend.sanitize_init_opts(
                 terminator_sup: :ignored,
                 boot_timeout: 1_234,
                 log: :debug
               )
    end
  end

  describe "encode_parent/4" do
    test "encodes parent payload with node_base and host_env" do
      encoded = K8sBackend.encode_parent(make_ref(), self(), "flame_example", "POD_IP")

      decoded =
        encoded
        |> Base.decode64!()
        |> :erlang.binary_to_term()

      assert is_reference(decoded.ref)
      assert is_pid(decoded.pid)
      assert decoded.backend == FLAME.K8sBackend
      assert decoded.node_base == "flame_example"
      assert decoded.host_env == "POD_IP"
    end
  end

  describe "extract_tracking_metadata/1" do
    test "keeps only supported Argo CD tracking keys" do
      resources = [
        %{
          "metadata" => %{
            "labels" => %{
              "app.kubernetes.io/instance" => "flame-app",
              "ignored" => "value"
            },
            "annotations" => %{
              "argocd.argoproj.io/tracking-id" =>
                "flame-app:apps/Deployment:default/flame-parent-example",
              "ignored" => "value"
            }
          }
        }
      ]

      assert %{
               "labels" => %{"app.kubernetes.io/instance" => "flame-app"},
               "annotations" => %{
                 "argocd.argoproj.io/tracking-id" =>
                   "flame-app:apps/Deployment:default/flame-parent-example"
               }
             } = K8sBackend.extract_tracking_metadata(resources)
    end

    test "later resources override earlier tracking metadata" do
      resources = [
        %{
          "metadata" => %{
            "labels" => %{"app.kubernetes.io/instance" => "from-pod"},
            "annotations" => %{
              "argocd.argoproj.io/tracking-id" => "old-tracking-id"
            }
          }
        },
        %{
          "metadata" => %{
            "labels" => %{
              "app.kubernetes.io/instance" => "from-workload",
              "argocd.argoproj.io/instance" => "custom-instance-key"
            },
            "annotations" => %{
              "argocd.argoproj.io/tracking-id" => "new-tracking-id",
              "argocd.argoproj.io/installation-id" => "cluster-a"
            }
          }
        }
      ]

      assert %{
               "labels" => %{
                 "app.kubernetes.io/instance" => "from-workload",
                 "argocd.argoproj.io/instance" => "custom-instance-key"
               },
               "annotations" => %{
                 "argocd.argoproj.io/tracking-id" => "new-tracking-id",
                 "argocd.argoproj.io/installation-id" => "cluster-a"
               }
             } = K8sBackend.extract_tracking_metadata(resources)
    end
  end

  describe "runner_annotations/2" do
    test "adds ignore-healthcheck by default" do
      assert %{
               "argocd.argoproj.io/ignore-healthcheck" => "true",
               "argocd.argoproj.io/tracking-id" => "runner-1"
             } =
               K8sBackend.runner_annotations(%{
                 "argocd.argoproj.io/tracking-id" => "runner-1"
               }, true)
    end

    test "allows opt-out of ignore-healthcheck" do
      assert %{"argocd.argoproj.io/tracking-id" => "runner-1"} =
               K8sBackend.runner_annotations(
                 %{"argocd.argoproj.io/tracking-id" => "runner-1"},
                 false
               )
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
