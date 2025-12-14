root_dir="$(get_root_dir)"
header "Cleaning up system"
bash "$root_dir/scripts/unix/cleanup.sh" "$root_dir"
