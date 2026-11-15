# Grafana V2 uses export labels, rather than classic-dashboard __inputs.
def datasource_reference:
  type == "object" and
  (.kind == "DataQuery" or .kind == "AdhocVariable" or .kind == "GroupByVariable");
def portable_reference:
  datasource_reference and
  (.datasource.name? | type == "string" and length > 0 and (startswith("$") | not)) and
  (.group != "grafana" and .group != "__expr__");

if .kind != "Dashboard" or (.apiVersion | startswith("dashboard.grafana.app/v2") | not)
then error("Expected a Grafana V2 dashboard resource") else . end
| if any(.spec.elements[]?; .kind == "LibraryPanel")
  then error("Library panels must be inlined before external export") else . end
| ([.spec | .. | objects | select(portable_reference) | {group, uid: .datasource.name}]
   | unique | group_by(.group)
   | map(to_entries | map(.value + {label: (.value.group + "-" + ((.key + 1) | tostring))}))
   | add // []) as $sources
| .metadata = {name: .metadata.name}
| del(.status)
| .spec |= walk(
    if portable_reference then
      . as $ref
      | ($sources[] | select(.group == $ref.group and .uid == $ref.datasource.name)) as $source
      | .labels = ((.labels // {}) + {"grafana.app/export-label": $source.label})
      | del(.datasource)
    elif type == "object" and .kind == "QueryVariable" then
      .spec.options = [] | .spec.current = {text: "", value: ""}
    elif type == "object" and .kind == "DatasourceVariable" then
      .spec.current = {text: "", value: ""}
    else . end
  )
