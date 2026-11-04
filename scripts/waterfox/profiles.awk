# Read only the profile registration fields; values may contain spaces or '='.
function flush() {
  if (section ~ /^Profile/ && path != "")
    printf "profile\t%s\t%s\t%s\t%s\n", (name != "" ? name : section), path, relative, isdefault
  if (section ~ /^Install/ && isdefault != "")
    printf "install\t-\t%s\t1\t0\n", isdefault
}
/^[[:space:]]*[#;]/ { next }
/^[[:space:]]*\[/ {
  flush(); section=$0; sub(/^[[:space:]]*\[/, "", section); sub(/\][[:space:]]*$/, "", section)
  name=""; path=""; relative="1"; isdefault=""; next
}
index($0, "=") {
  key=substr($0, 1, index($0, "=")-1); value=substr($0, index($0, "=")+1)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
  key=tolower(key)
  if (key == "name") name=value
  if (key == "path") path=value
  if (key == "isrelative") relative=value
  if (key == "default") isdefault=value
}
END { flush() }
