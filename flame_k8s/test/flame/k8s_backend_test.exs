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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
