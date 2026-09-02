defmodule Mix.Tasks.Flame.Gen.DeploymentTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  test "prints a deployment manifest with flame annotations" do
    output =
      capture_io(fn ->
        Mix.Tasks.Flame.Gen.Deployment.run([
          "--name",
          "flame-parent-example",
          "--namespace",
          "default",
          "--image",
          "ghcr.io/eigr-labs/flame-parent-example:latest"
        ])
      end)

    assert output =~ "kind: Deployment"
    assert output =~ "name: flame-parent-example"
    assert output =~ "namespace: default"
    assert output =~ "flame.org/enabled: \"true\""
    assert output =~ "flame.org/pool-config-ref: \"default-pool\""
    assert output =~ "flame.org/dist-auto-config: \"true\""
    assert output =~ "flame.org/otp-app: \"flame_app\""
    assert output =~ "flame.org/runner-termination-timeout: \"60000\""
    assert output =~ "flame.org/cookie-secret-ref: \"flame-erlang-cookie\""
    assert output =~ "image: ghcr.io/eigr-labs/flame-parent-example:latest"
  end
end
