defmodule FlameK8sController.Versions.Api.V1.FlamePool do
  @moduledoc """
  Defines the v1 version of the FlamePool CRD.

  FlamePool provides configuration templates for FLAME runners.
  These templates are referenced by parent applications when spawning runner pods.
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
              required: [:podTemplate],
              description: "Specification of the FlamePool configuration",
              properties: %{
                podTemplate: %{
                  type: :object,
                  description:
                    "Pod template specification for FLAME runners. This follows the standard Kubernetes Pod template structure.",
                  properties: %{
                    metadata: %{
                      type: :object,
                      description: "Metadata to apply to runner pods",
                      properties: %{
                        labels: %{
                          type: :object,
                          additionalProperties: %{type: :string},
                          description: "Labels to apply to runner pods"
                        },
                        annotations: %{
                          type: :object,
                          additionalProperties: %{type: :string},
                          description: "Annotations to apply to runner pods"
                        }
                      }
                    },
                    spec: %{
                      type: :object,
                      description:
                        "Pod specification for runner pods. Follows Kubernetes Pod spec structure.",
                      # Allow any pod spec fields - Kubernetes will validate these
                      "x-kubernetes-preserve-unknown-fields": true
                    }
                  },
                  required: [:spec]
                }
              }
            },
            status: %{
              type: :object,
              description: "Status of the FlamePool",
              properties: %{
                observedGeneration: %{
                  type: :integer,
                  description:
                    "The generation observed by the controller. Used to track reconciliation progress."
                },
                conditions: %{
                  type: :array,
                  description: "Current conditions of the FlamePool",
                  items: %{
                    type: :object,
                    required: [:type, :status],
                    properties: %{
                      type: %{
                        type: :string,
                        description: "Type of condition (e.g., Ready, Valid)"
                      },
                      status: %{
                        type: :string,
                        enum: ["True", "False", "Unknown"],
                        description: "Status of the condition"
                      },
                      lastTransitionTime: %{
                        type: :string,
                        format: "date-time",
                        description: "Last time the condition transitioned"
                      },
                      reason: %{
                        type: :string,
                        description: "Machine-readable reason for the condition"
                      },
                      message: %{
                        type: :string,
                        description: "Human-readable message about the condition"
                      }
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
          name: "Age",
          type: :date,
          jsonPath: ".metadata.creationTimestamp",
          description: "Age of the FlamePool"
        }
      ]
    )
    |> add_observed_generation_status()
  end
end
