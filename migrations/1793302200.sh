echo "Stop Sunshine Admin from disabling browser certificate checks"

# Older installs wrote a desktop launcher that passed Chromium's
# --ignore-certificate-errors switch through to the user's browser. That
# switch is not limited to the Sunshine origin. Leave every other launcher
# alone, including one the user edited.

desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
[[ -d $desktop_dir ]] || exit 0

old_exec='Exec=omarchy-launch-webapp https://localhost:47990 --ignore-certificate-errors'
new_exec='Exec=omarchy-launch-webapp https://localhost:47990'

shopt -s nullglob
for desktop in "$desktop_dir"/*.desktop; do
  grep -qxF "$old_exec" "$desktop" || continue
  tmp=$(mktemp "$desktop_dir/.sunshine-admin.XXXXXX")
  awk -v old="$old_exec" -v new="$new_exec" '$0 == old { print new; next } { print }' "$desktop" >"$tmp"
  mv "$tmp" "$desktop"
done
