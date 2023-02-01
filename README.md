# nixos-packer

# tailscale and mosh on instance startup

```
metadata_startup_script = <<-EOS
#! /run/current-system/sw/bin/nix-shell
#! nix-shell -i bash -p tailscale mosh

tailscale up --ssh=true --auth-key ${var.tailscale_auth_key}
mosh-server
EOS
```
