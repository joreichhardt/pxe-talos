# RB5009 Terraform fuer `pxe-talos`

Diese Konfiguration richtet den MikroTik RB5009 passend zum Rest des Repos als VLAN-aware Switch ein:

- `ether1` haengt upstream.
- Welche Adresse oder welches Gateway dort konkret anliegt, ist fuer diese Terraform egal.
- Der Zugriff auf den RB5009 fuer Terraform kann z. B. ueber die bestehende Management-IP `192.168.88.1` erfolgen.
- Das PXE-/Talos-Lab bleibt auf VLAN `10`.
- Die Raspberry Pi aus diesem Repo bleibt der einzige DHCP-, PXE-, DNS- und NAT-Knoten fuer das Lab.

Die Konfiguration fuegt absichtlich **kein** DHCP, **kein** NAT und **keine** Router-Funktion auf dem RB5009 hinzu. Das bleibt auf der Pi, so wie es `README.md` und `docs/design.md` im Hauptprojekt vorsehen.

## Default-Portbelegung

Mit den Default-Variablen ergibt sich:

| Port | Rolle |
|---|---|
| `ether1` | Upstream/Home-LAN untagged |
| `ether2` | Trunk zur Pi, Home-LAN untagged + VLAN 10 tagged |
| `ether3`-`ether8` | Access-Ports fuer Talos-/PXE-Nodes auf VLAN 10 |
| `sfp-sfpplus1` | unbenutzt, kann spaeter ueber `downstream_trunk_ports` oder `home_access_ports` belegt werden |

## Voraussetzungen

Die Konfiguration ist fuer einen **frischen oder bereinigten RouterOS-Stand** gedacht. Auf einem RB5009 mit Default-Konfiguration kollidieren in der Regel bereits vorhandene Bridge-Eintraege mit Terraform.

Praktisch heisst das:

1. RouterOS auf einen sauberen Stand bringen, idealerweise ohne Default-Konfiguration.
2. REST/API fuer den Provider aktivieren. Laut Provider-Doku funktioniert der aktuelle Provider mit RouterOS 7.x und einem aktivierten `web-ssl`-Dienst.
3. Einen Benutzer fuer Terraform anlegen.
4. Falls der RB5009 bereits eine Management-IP wie `192.168.88.1` hat, diese vor dem Apply einplanen und als `routeros_hosturl` verwenden.
5. Wichtig: `https://192.168.88.1` nutzt den RouterOS-REST-Zugang ueber `web-ssl`. `apis://192.168.88.1:8729` nutzt dagegen den separaten API-SSL-Dienst. Ein TLS-Handshake-Fehler kommt oft daher, dass `apis://` konfiguriert ist, aber nur `web-ssl` aktiv ist.

## Dateien

- [versions.tf](/home/jre/dev/pxe-talos/terraform/mikrotik-rb5009/versions.tf)
- [variables.tf](/home/jre/dev/pxe-talos/terraform/mikrotik-rb5009/variables.tf)
- [main.tf](/home/jre/dev/pxe-talos/terraform/mikrotik-rb5009/main.tf)
- [outputs.tf](/home/jre/dev/pxe-talos/terraform/mikrotik-rb5009/outputs.tf)
- [terraform.tfvars.example](/home/jre/dev/pxe-talos/terraform/mikrotik-rb5009/terraform.tfvars.example)

## Verwendung

```bash
cd terraform/mikrotik-rb5009
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
terraform init
terraform plan
terraform apply
```

Wenn du aktuell `apis://192.168.88.1` verwendest, probiere zuerst:

```hcl
routeros_hosturl  = "https://192.168.88.1"
routeros_insecure = true
```

Nur wenn auf dem MikroTik wirklich `api-ssl` aktiviert ist, solltest du stattdessen `apis://192.168.88.1:8729` verwenden.

## Was Terraform konfiguriert

- eine VLAN-aware Bridge mit `rstp`
- Bridge-Ports fuer Uplink, Pi-Trunk und Lab-Access
- native Home-LAN-Mitgliedschaft auf dem Uplink und den Trunks
- VLAN-10-Tagging auf dem Pi-Trunk
- VLAN-10-Untagging auf den Node-Ports

## Was Terraform bewusst nicht konfiguriert

- kein DHCP auf dem RB5009
- kein NAT auf dem RB5009
- keine Router-Funktion auf dem RB5009

Management erfolgt ueber die Upstream-Adresse des RB5009, z. B. die DHCP-Adresse aus dem Fritzbox-LAN. Der PXE-DHCP fuer VLAN `10` bleibt auf der Pi.

## Bezug zum Hauptprojekt

Die Netzannahmen passen direkt zu den bestehenden Repo-Defaults:

- Home-LAN untagged / native
- Lab-VLAN `10`
- Pi-Lab-IP `10.10.0.1/24`
- PXE/DHCP fuer VLAN 10 ausschliesslich auf der Pi

Wenn du spaeter andere Ports oder ein zusaetzliches Downstream-Trunking willst, musst du nur `pi_trunk_ports`, `lab_access_ports`, `home_access_ports` oder `downstream_trunk_ports` in `terraform.tfvars` anpassen.
