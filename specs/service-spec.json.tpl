{
    "name": "Path Router",
    "slug": "path-router",
    "type": "dependency",
    "visible_to": ["{{ env.Getenv `NRN` }}"],
    "dimensions": {},
    "scopes": {},
    "assignable_to": "any",
    "use_default_actions": true,
    "attributes": {
        "schema": {
            "type": "object",
            "$schema": "http://json-schema.org/draft-07/schema#",
            "required": ["base_domain", "path_prefix", "scope"],
            "uiSchema": {
                "type": "VerticalLayout",
                "elements": [
                    {
                        "type": "Control",
                        "label": "Base Domain",
                        "scope": "#/properties/base_domain"
                    },
                    {
                        "type": "Control",
                        "label": "Strip path prefix before forwarding",
                        "scope": "#/properties/strip_prefix"
                    },
                    {
                        "type": "HorizontalLayout",
                        "elements": [
                            {
                                "type": "Control",
                                "label": "Path Prefix",
                                "scope": "#/properties/path_prefix"
                            },
                            {
                                "type": "Control",
                                "label": "Scope",
                                "scope": "#/properties/scope"
                            }
                        ]
                    }
                ]
            },
            "properties": {
                "base_domain": {
                    "type": "string",
                    "title": "Base Domain",
                    "description": "Shared domain for path-based routing.",
                    "enum": ["path-router.api-private.playground.nullapps.io"]
                },
                "strip_prefix": {
                    "type": "boolean",
                    "title": "Strip path prefix",
                    "description": "Remove the path prefix before forwarding to the backend. When enabled, /APP1/health is forwarded as /health.",
                    "default": true
                },
                "path_prefix": {
                    "type": "string",
                    "title": "Path Prefix",
                    "pattern": "^/[a-zA-Z0-9_\\-]+$",
                    "description": "Path prefix to route to this application. Example: /APP1, /api-gateway"
                },
                "scope": {
                    "type": "string",
                    "title": "Scope",
                    "description": "Target scope to route traffic to.",
                    "additionalKeywords": {
                        "enum": "[.scopes[]?.slug] | if length == 0 then [\"No scopes available for selected environment\"] else . end"
                    }
                }
            }
        },
        "values": {}
    },
    "selectors": {
        "category": "Networking",
        "imported": false,
        "provider": "Istio",
        "sub_category": "Path Routing"
    }
}
