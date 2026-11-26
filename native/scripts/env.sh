# Source this file in a Linux shell; it does not install anything.
# Fixed official Debian 13 x86_64 tarball installation.
eros_swift_bin="$HOME/.local/opt/swift-6.4.2-RELEASE-debian13/usr/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$eros_swift_bin:"*) ;;
  *) export PATH="$eros_swift_bin:$PATH" ;;
esac
unset eros_swift_bin
