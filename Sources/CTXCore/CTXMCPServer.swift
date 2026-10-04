import Foundation

public final class CTXMCPServer: @unchecked Sendable {
    public static let shared = CTXMCPServer()

    private let discoveryService: KubeConfigDiscoveryService
    private let reader: KubernetesResourceReader
    private let validator: KubernetesConfigurationValidator
    private let applier: KubernetesYAMLApplier
    private let auditLog: any AuditLogging
    private let logsReader: KubernetesLogsReading

    public init(
        discoveryService: KubeConfigDiscoveryService = KubeConfigDiscoveryService(),
        reader: KubernetesResourceReader = KubernetesResourceReader(),
        validator: KubernetesConfigurationValidator = KubernetesConfigurationValidator(),
        applier: KubernetesYAMLApplier = KubernetesYAMLApplier(),
        auditLog: any AuditLogging = LocalAuditLogService(),
        logsReader: KubernetesLogsReading = KubernetesLogsReader()
    ) {
        self.discoveryService = discoveryService
        self.reader = reader
        self.validator = validator
        self.applier = applier
        self.auditLog = auditLog
        self.logsReader = logsReader
    }

    public static func runStdio() {
        let server = CTXMCPServer()
        server.startStdioLoop()
    }

    public func startStdioLoop() {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            handleMessage(trimmed)
        }
    }

    public func handleMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            sendResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": [String: Any]()
                ],
                "serverInfo": [
                    "name": "ctx-mcp",
                    "version": "1.0.0"
                ]
            ])

        case "notifications/initialized":
            // Notification, no reply expected
            break

        case "tools/list":
            sendResult(id: id, result: [
                "tools": [
                    [
                        "name": "ctx_list_contexts",
                        "description": "Lists all Kubernetes cluster contexts discovered in local kubeconfigs.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [String: Any]()
                        ]
                    ],
                    [
                        "name": "ctx_get_resources",
                        "description": "Fetches live Kubernetes resources (pods, nodes, workloads, services, ingress, pvc, configMaps, etc.).",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "kind": [
                                    "type": "string",
                                    "description": "Resource kind (e.g. pods, nodes, workloads, services, ingress, pvc, cronJobs, events, hpa)"
                                ],
                                "context": [
                                    "type": "string",
                                    "description": "Optional cluster context name. If omitted, uses the current or first discovered context."
                                ],
                                "namespace": [
                                    "type": "string",
                                    "description": "Optional namespace. If omitted, queries default namespace or cluster scope."
                                ]
                            ],
                            "required": ["kind"]
                        ]
                    ],
                    [
                        "name": "ctx_get_logs",
                        "description": "Retrieves recent live logs for a pod or specific container for real-time troubleshooting.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "pod": [
                                    "type": "string",
                                    "description": "Name of the pod."
                                ],
                                "container": [
                                    "type": "string",
                                    "description": "Optional container name within the pod."
                                ],
                                "namespace": [
                                    "type": "string",
                                    "description": "Optional namespace (defaults to the context default namespace)."
                                ],
                                "context": [
                                    "type": "string",
                                    "description": "Optional cluster context name."
                                ],
                                "tailLines": [
                                    "type": "integer",
                                    "description": "Number of log lines to retrieve (default 100, max 2000)."
                                ]
                            ],
                            "required": ["pod"]
                        ]
                    ],
                    [
                        "name": "ctx_validate_diagnostics",
                        "description": "Runs CTX's cross-resource diagnostic validation engine to detect broken selectors, missing secrets/configmaps, security risks, and reliability issues.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "context": [
                                    "type": "string",
                                    "description": "Optional cluster context name."
                                ],
                                "namespace": [
                                    "type": "string",
                                    "description": "Optional namespace."
                                ]
                            ]
                        ]
                    ],
                    [
                        "name": "ctx_dry_run_yaml",
                        "description": "Validates a Kubernetes manifest YAML against the API server using server dry-run (--dry-run=server) without applying any change.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "yaml": [
                                    "type": "string",
                                    "description": "The YAML manifest to validate."
                                ],
                                "context": [
                                    "type": "string",
                                    "description": "Optional cluster context name."
                                ],
                                "namespace": [
                                    "type": "string",
                                    "description": "Optional target namespace."
                                ]
                            ],
                            "required": ["yaml"]
                        ]
                    ],
                    [
                        "name": "ctx_apply_yaml",
                        "description": "Applies a Kubernetes manifest YAML to the cluster.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "yaml": [
                                    "type": "string",
                                    "description": "The YAML manifest to apply."
                                ],
                                "context": [
                                    "type": "string",
                                    "description": "Optional cluster context name."
                                ],
                                "namespace": [
                                    "type": "string",
                                    "description": "Optional target namespace."
                                ]
                            ],
                            "required": ["yaml"]
                        ]
                    ]
                ]
            ])

        case "tools/call":
            handleToolCall(id: id, params: params)

        default:
            if id != nil {
                sendError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) {
        guard let name = params["name"] as? String else {
            sendError(id: id, code: -32602, message: "Missing tool name")
            return
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        Task {
            switch name {
            case "ctx_list_contexts":
                let discovered = self.discoveryService.discover()
                let contexts = discovered.contexts.map { ctx in
                    [
                        "name": ctx.contextName,
                        "cluster": ctx.clusterName,
                        "user": ctx.userName,
                        "namespace": ctx.namespace.isEmpty ? "default" : ctx.namespace,
                        "isCurrent": ctx.isCurrent
                    ]
                }
                self.sendToolResult(id: id, content: self.jsonString(contexts))

            case "ctx_get_resources":
                guard let kindStr = arguments["kind"] as? String,
                      let kind = KubernetesResourceKind(rawValue: kindStr) ?? KubernetesResourceKind.allCases.first(where: { $0.title.lowercased() == kindStr.lowercased() }) else {
                    self.sendToolError(id: id, message: "Invalid or unsupported resource kind")
                    return
                }

                guard let context = self.resolveContext(named: arguments["context"] as? String) else {
                    self.sendToolError(id: id, message: "No active or specified Kubernetes context found")
                    return
                }

                let nsSelection = self.resolveNamespace(arguments["namespace"] as? String)
                let list = await self.reader.list(kind: kind, context: context, namespace: nsSelection)
                let rowData = list.rows.map { row in
                    [
                        "id": row.id,
                        "name": row.name,
                        "namespace": row.namespace ?? "-",
                        "cells": row.cells,
                        "warning": row.warning
                    ] as [String: Any]
                }
                self.sendToolResult(id: id, content: self.jsonString(rowData))

            case "ctx_get_logs":
                guard let pod = arguments["pod"] as? String else {
                    self.sendToolError(id: id, message: "Missing required pod argument")
                    return
                }

                guard let context = self.resolveContext(named: arguments["context"] as? String) else {
                    self.sendToolError(id: id, message: "No active or specified Kubernetes context found")
                    return
                }

                let ns = (arguments["namespace"] as? String) ?? (context.namespace.isEmpty ? "default" : context.namespace)
                let container = arguments["container"] as? String
                let tail = min(arguments["tailLines"] as? Int ?? 100, 2000)

                let logResult = await self.logsReader.logs(
                    namespace: ns,
                    pod: pod,
                    container: container,
                    tailLines: tail,
                    context: context
                )

                if let logText = logResult.text {
                    self.sendToolResult(id: id, content: logText)
                } else if let diag = logResult.diagnostic {
                    self.sendToolError(id: id, message: diag.stderrSummary)
                } else {
                    self.sendToolError(id: id, message: "Failed to read logs for pod \(pod)")
                }

            case "ctx_validate_diagnostics":
                guard let context = self.resolveContext(named: arguments["context"] as? String) else {
                    self.sendToolError(id: id, message: "No active or specified Kubernetes context found")
                    return
                }

                let nsSelection = self.resolveNamespace(arguments["namespace"] as? String)
                let kindsToScan: [KubernetesResourceKind] = [.pods, .nodes, .workloads, .services, .ingress, .configMaps, .secretMetadata, .pvc]
                let batch = await self.reader.batchList(kinds: kindsToScan, context: context, namespace: nsSelection)
                let report = KubernetesConfigurationValidator.validate(batch: batch)
                let issueData = report.allIssues.map { issue in
                    [
                        "ruleId": issue.ruleId,
                        "severity": issue.severity.rawValue,
                        "category": issue.category.rawValue,
                        "resourceKind": issue.resourceKind.rawValue,
                        "resourceName": issue.resourceName,
                        "namespace": issue.resourceNamespace ?? "-",
                        "title": issue.title,
                        "message": issue.message,
                        "recommendation": issue.recommendation
                    ]
                }
                self.sendToolResult(id: id, content: self.jsonString(issueData))

            case "ctx_dry_run_yaml":
                guard let yaml = arguments["yaml"] as? String else {
                    self.sendToolError(id: id, message: "Missing 'yaml' argument")
                    return
                }

                guard let context = self.resolveContext(named: arguments["context"] as? String) else {
                    self.sendToolError(id: id, message: "No active or specified Kubernetes context found")
                    return
                }

                let ns = arguments["namespace"] as? String
                let res = await self.applier.dryRun(yaml: yaml, context: context, namespace: ns)
                try? self.auditLog.record(AuditEvent(type: .yamlDryRun, contextName: context.contextName, message: "mcp dry-run: \(res.message)"))
                let payload: [String: Any] = [
                    "success": res.success,
                    "isDryRun": res.isDryRun,
                    "message": res.message,
                    "errorDetails": res.errorDetails ?? "",
                    "stdout": res.stdout
                ]
                self.sendToolResult(id: id, content: self.jsonString(payload))

            case "ctx_apply_yaml":
                guard let yaml = arguments["yaml"] as? String else {
                    self.sendToolError(id: id, message: "Missing 'yaml' argument")
                    return
                }

                guard let context = self.resolveContext(named: arguments["context"] as? String) else {
                    self.sendToolError(id: id, message: "No active or specified Kubernetes context found")
                    return
                }

                guard UserDefaults.standard.bool(forKey: CTXDefaultsKey.mcpApplyEnabled) else {
                    try? self.auditLog.record(AuditEvent(type: .mcpApplyBlocked, contextName: context.contextName, message: "ctx_apply_yaml blocked: disabled in CTX Settings \u{2192} MCP"))
                    self.sendToolError(id: id, message: "ctx_apply_yaml is disabled. Enable \"Allow AI apply\" in CTX Settings \u{2192} MCP to let a connected client mutate this cluster.")
                    return
                }

                let ns = arguments["namespace"] as? String
                let res = await self.applier.apply(yaml: yaml, context: context, namespace: ns)
                try? self.auditLog.record(AuditEvent(type: res.success ? .yamlApplied : .yamlApplyFailed, contextName: context.contextName, message: "mcp apply: \(res.message)"))
                let payload: [String: Any] = [
                    "success": res.success,
                    "isDryRun": res.isDryRun,
                    "message": res.message,
                    "errorDetails": res.errorDetails ?? "",
                    "stdout": res.stdout
                ]
                self.sendToolResult(id: id, content: self.jsonString(payload))

            default:
                self.sendError(id: id, code: -32601, message: "Unknown tool: \(name)")
            }
        }
    }

    private func resolveContext(named name: String?) -> KubernetesContextProfile? {
        let discovered = discoveryService.discover()
        if let name = name, !name.isEmpty {
            return discovered.contexts.first { $0.contextName == name }
        }
        return discovered.contexts.first { $0.isCurrent } ?? discovered.contexts.first
    }

    private func resolveNamespace(_ raw: String?) -> KubernetesNamespaceSelection {
        guard let raw = raw, !raw.isEmpty, raw != "__all__" else {
            return .defaultNamespace
        }
        if raw.lowercased() == "all" || raw == "--all-namespaces" {
            return .allNamespaces
        }
        return .namespace(raw)
    }

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private func sendToolResult(id: Any?, content: String) {
        sendResult(id: id, result: [
            "content": [
                [
                    "type": "text",
                    "text": content
                ]
            ]
        ])
    }

    private func sendToolError(id: Any?, message: String) {
        sendResult(id: id, result: [
            "isError": true,
            "content": [
                [
                    "type": "text",
                    "text": message
                ]
            ]
        ])
    }

    private func sendResult(id: Any?, result: [String: Any]) {
        guard let id = id else { return }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        sendOutput(response)
    }

    private func sendError(id: Any?, code: Int, message: String) {
        guard let id = id else { return }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ]
        sendOutput(response)
    }

    private func sendOutput(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
