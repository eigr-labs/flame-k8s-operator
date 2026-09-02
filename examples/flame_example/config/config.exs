import Config

config :logger, :console,
  format: "$date $time [$node]:[$metadata]:[$level]:$message\n",
  metadata: [:pid, :span_id, :trace_id]

if config_env() == :prod do
  config :flame, :backend, FLAME.K8sBackend
  config :flame, FLAME.K8sBackend, log: :debug
end
