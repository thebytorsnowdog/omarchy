echo "Require signed packages from the Omarchy repository"

# bin/omarchy-upgrade-to-quattro writes "SigLevel = Optional TrustAll" for the
# [omarchy] section so the packaging key can be installed. Migration
# 1787589206 removes that line once. Re-running the upgrade after that marker
# exists puts the line back, and this pass removes it again when the key is
# present. A machine that never gained the override no-ops.

omarchy_sig_override='SigLevel = Optional TrustAll'

if [[ -f /etc/pacman.conf ]] &&
  sed -n '/^\[omarchy\]/,/^\[/p' /etc/pacman.conf | grep -qxF "$omarchy_sig_override"; then
  if omarchy-pkg-missing omarchy-keyring ||
    ! sudo pacman-key --list-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571 &>/dev/null; then
    omarchy-update-keyring
  fi

  sudo sed -i "/^\[omarchy\]/,/^\[/{/^$omarchy_sig_override$/d}" /etc/pacman.conf
fi
