<!-- talk-integration-guide:1 -->
# {{display_name}} integration guide

```json
{
  "formatVersion": 1,
  "app": "{{app_slug}}",
  "displayName": "{{display_name}}",
  "guideVersion": "1.0.0",
  "updated": "{{YYYY-MM-DD}}",
  "status": "draft",
  "roles": ["{{provider_or_consumer}}"],
  "sdk": {
    "repository": "https://github.com/AppitStudio/Talk.swift.git",
    "version": "0.1.0-beta.2"
  },
  "provider": {
    "bundleID": "{{public_routing_bundle_id}}",
    "contract": "Contract/Sources/{{module}}/Contract.talk.json",
    "contractID": "{{actual_contract_id}}",
    "contractVersion": "{{actual_contract_version}}",
    "sha256": "{{canonical_export_sha256}}",
    "module": "{{module}}"
  },
  "consumes": []
}
```

## Purpose and roles

{{purpose}}

## Compatibility and prerequisites

{{prerequisites}}

## Public contract

{{contract}}

## Actions, permissions, and side effects

{{permissions}}

## Connection lifecycle

{{lifecycle}}

## Typed implementation

{{implementation}}

## Errors and recovery

{{errors}}

## Integration experience

{{experience}}

## Validation evidence

{{evidence}}

## Maintenance and support

{{maintenance}}
