defmodule FlameK8sController.Versions.Api.V1.FlameRunner do
  @moduledoc """
  Defines the v1 version of the FlameRunner CRD.

  FlameRunner represents an ephemeral runner pod created by FLAME
  for elastic compute workloads. These are typically created dynamically
  by parent applications and cleaned up after use.
  """
  use Bonny.API.Version

  @impl true
  def manifest() do
    defaults()
    |> struct!(
      name: "v1",
      storage: true,
      schema: %{
        openAPIV3Schema: %{
          type: :object,
          required: [:spec],
          properties: %{
            spec: %{
              type: :object,
              required: [:parentRef, :image],
              description: "Specification of the FlameRunner",
              properties: %{
                parentRef: %{
                  type: :object,
                  required: [:name, :namespace],
                  description: "Reference to the parent application that spawned this runner",
                  properties: %{
                    name: %{
                      type: :string,
                      description: "Name of the parent pod"
                    },
                    namespace: %{
                      type: :string,
                      description: "Namespace of the parent pod"
                    },
                    uid: %{
                      type: :string,
                      description: "UID of the parent pod for ownership tracking"
                    }
                  }
                },
                image: %{
                  type: :string,
                  description: "Container image to use for the runner pod",
                  minLength: 1
                },
                poolRef: %{
                  type: :string,
                  description:
                    "Reference to a FlamePool for configuration template. If not specified, uses 'default-pool'",
                  default: "default-pool"
                },
                env: %{
                  type: :array,
                  description: "Additional environment variables for the runner",
                  items: %{
                    type: :object,
                    required: [:name],
                    properties: %{
                      name: %{type: :string},
                      value: %{type: :string},
                      valueFrom: %{
                        type: :object,
                        "x-kubernetes-preserve-unknown-fields": true
                      }
                    }
                  }
                },
                resources: %{
                  type: :object,
                  description: "Override resource requirements from the pool template",
                  properties: %{
                    limits: %{
                      type: :object,
                      additionalProperties: %{
                        anyOf: [%{type: :string}, %{type: :integer}]
                      }
                    },
                    requests: %{
                      type: :object,
                      additionalProperties: %{
                        anyOf: [%{type: :string}, %{type: :integer}]
                      }
                    }
                  }
                },
                terminationGracePeriodSeconds: %{
                  type: :integer,
                  description: "Grace period before forcefully terminating the runner",
                  default: 60,
                  minimum: 0
                }
              }
            },
            status: %{
              type: :object,
              description: "Status of the FlameRunner",
              properties: %{
                observedGeneration: %{
                  type: :integer,
                  description: "The generation observed by the controller"
                },
                phase: %{
                  type: :string,
                  enum: ["Pending", "Running", "Succeeded", "Failed", "Terminating"],
                  description: "Current phase of the runner pod"
                },
                podName: %{
                  type: :string,
                  description: "Name of the created pod"
                },
                podIP: %{
                  type: :string,
                  description: "IP address of the runner pod"
                },
                startTime: %{
                  type: :string,
                  format: "date-time",
                  description: "Time when the runner started"
                },
                completionTime: %{
                  type: :string,
                  format: "date-time",
                  description: "Time when the runner completed"
                },
                conditions: %{
                  type: :array,
                  description: "Current conditions of the FlameRunner",
                  items: %{
                    type: :object,
                    required: [:type, :status],
                    properties: %{
                      type: %{
                        type: :string,
                        description: "Type of condition (e.g., Ready, PodScheduled)"
                      },
                      status: %{
                        type: :string,
                        enum: ["True", "False", "Unknown"],
                        description: "Status of the condition"
                      },
                      lastTransitionTime: %{
                        type: :string,
                        format: "date-time"
                      },
                      reason: %{type: :string},
                      message: %{type: :string}
                    }
                  }
                }
              }
            }
          }
        }
      },
      additionalPrinterColumns: [
        %{
          name: "Phase",
          type: :string,
          jsonPath: ".status.phase",
          description: "Current phase of the runner"
        },
        %{
          name: "Pool",
          type: :string,
          jsonPath: ".spec.poolRef",
          description: "FlamePool used for configuration"
        },
        %{
          name: "Pod",
          type: :string,
          jsonPath: ".status.podName",
          description: "Name of the runner pod"
        },
        %{
          name: "Age",
          type: :date,
          jsonPath: ".metadata.creationTimestamp",
          description: "Age of the FlameRunner"
        }
      ]
    )
    |> add_observed_generation_status()
  end
end
