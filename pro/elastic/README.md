# OpenVidu Pro — Elastic Deployment on Oracle Cloud Infrastructure (OCI)

Documento técnico exhaustivo de **cómo funciona** el despliegue Elastic de OpenVidu Pro en OCI definido por este módulo Terraform. Está pensado como material de origen para que Claude (u otra IA) genere documentación de usuario, guías paso a paso y diagramas.

> No es una guía “oficial” de instalación de cara al usuario final — es la referencia interna que describe **toda la arquitectura, los recursos, los flujos y los porqués**.

---

## 1. Visión general del despliegue

El despliegue Elastic de OpenVidu en OCI consta de:

- **1 Master Node** (instancia OCI única, sin alta disponibilidad) que ejecuta:
  - El plano de control de OpenVidu (`openvidu` container), Caddy, Redis, MongoDB, MinIO/proxy a S3, Grafana, OpenVidu Meet, Dashboard, etc.
  - Cron jobs para invocar la función de scale-in y limpiar volúmenes huérfanos.
- **N Media Nodes** (1 ≤ N ≤ max) dentro de un **OCI Instance Pool**:
  - Ejecutan los workloads de media (LiveKit, ingress, egress, agentes).
  - Escalan **automáticamente**:
    - **Scale-out**: OCI Autoscaling (regla nativa de CPU).
    - **Scale-in**: una **OCI Function** custom (`func.py`) decide cuándo y a quién retirar; el nodo retirado se drena solo y se autotermina.
- **OCI Function** (`openvidu-scalein`) en lenguaje Python que orquesta el scale-in “con drenaje”.
- **OCI KMS Vault + Key** que actúa como almacén compartido de secretos entre el master y los media nodes (passwords, license, dominios, etc.).
- **OCI Object Storage** (S3-compatible) para datos persistentes y grabaciones.
- **Red dedicada**: VCN propia, Internet Gateway, Subnet pública, Security List y dos Network Security Groups (master / media) con reglas finas para tráfico inter-nodos y desde internet.
- **IAM**: Dynamic Groups + Policies que conceden a las instancias y a la función los permisos mínimos para hablar con la API de OCI vía **Instance Principal / Resource Principal** (sin credenciales locales).

Hay un **modo “fijo”** opcional (`fixedNumberOfMediaNodes > 0`) que despliega N media nodes inmutables sin autoscaling y sin función de scale-in.

---

## 2. Estructura del módulo

Ruta: `pro/elastic/`

| Archivo | Propósito |
|--------|-----------|
| `tf-oracle-openvidu-elastic.tf` | Definición Terraform completa (~2070 líneas): red, IAM, vault, instancia master, instance pool, autoscaling, función, scripts cloud-init. |
| `variables.tf` | Declaración y validación de todas las variables de entrada del módulo. |
| `versions.tf` | Versiones de Terraform y providers (`oracle/oci`, `hashicorp/random`, `hashicorp/tls`, `hashicorp/time`). |
| `output.tf` | Outputs del módulo (instrucciones para recuperar credenciales por SSH). |
| `terraform.tfvars.example` | Plantilla comentada de variables con todos los valores opcionales documentados. |

Ruta hermana: `pro/scalein-function/` — fuente de la OCI Function:

| Archivo | Propósito |
|--------|-----------|
| `func.py` | Lógica de la función (`handler`, evaluación de scale-in y terminate). |
| `Dockerfile` | Imagen multi-stage; en build se purgan los subpaquetes del SDK OCI no usados para reducir ~430 MB. |
| `requirements.txt` | Dependencias Python (FDK + OCI SDK). |
| `build-and-push.sh` | Script de build con escaneo de secretos antes de subir a OCIR. |
| `.dockerignore` | Exclusiones de build. |

---

## 3. Variables de entrada (`variables.tf` + `terraform.tfvars.example`)

### 3.1 Obligatorias

| Variable | Tipo | Descripción |
|---------|------|-------------|
| `tenancy_ocid` | string | OCID de la tenancy (necesario para namespace de Object Storage y dynamic groups en root). |
| `compartment_ocid` | string | Compartment donde se crean los recursos. |
| `user_ocid` | string | Usuario al que se asocia el `Customer Secret Key` para acceso S3-compatible. |
| `stackName` | string | Nombre lógico del despliegue (prefijo de display names y tags). |
| `openviduLicense` | string (sensitive) | Licencia OpenVidu Pro/Enterprise. |

### 3.2 Opcionales (con valores por defecto)

#### Región / AD
- `region` — default `eu-frankfurt-1`.
- `availability_domain` — 1 / 2 / 3 (validado), default 1.

#### Tamaño Master
- `masterNodeShape` — default `VM.Standard.E4.Flex`.
- `masterNodeOcpus` — default 2.
- `masterNodeMemory` — GB, default 8.
- `masterNodeDiskSize` — GB, default 100.

#### Tamaño Media
- `mediaNodeShape` — default `VM.Standard.E4.Flex`.
- `mediaNodeOcpus` — default 3.
- `mediaNodeMemory` — GB, default 4.
- `mediaNodeDiskSize` — GB, default 100.

#### Modo fijo vs Autoscaling
- `fixedNumberOfMediaNodes` — `>0` desactiva autoscaling y función de scale-in. Default 0 (elástico).

#### Autoscaling (sólo si `fixedNumberOfMediaNodes == 0`)
- `initialNumberOfMediaNodes` — default 1.
- `minNumberOfMediaNodes` — default 1.
- `maxNumberOfMediaNodes` — default 5.
- `scaleTargetCPU` — umbral CPU %, default 50 (dispara scale-out por encima, scale-in por debajo).

#### Dominio y SSL
- `certificateType` — `letsencrypt` (default) | `selfsigned` | `owncert`.
- `domainName` — si vacío y `letsencrypt`, se genera un subdominio `sslip.io`.
- `publicIpAddress` — IP pública reservada previamente (opcional); validada como IPv4.
- `ownPublicCertificate` / `ownPrivateCertificate` — base64 (sólo `owncert`).

#### Seguridad y acceso
- `initialMeetAdminPassword` — password del usuario admin de Meet. Si vacío, se genera aleatorio.
- `initialMeetApiKey` — API key inicial de Meet. Si vacío, no se configura.

#### Media engine
- `rtcEngine` — `pion` (default) | `mediasoup`. Validado.

#### Storage
- `bucketName` — bucket existente. Si vacío, se crea uno con sufijo aleatorio.

#### Vault / KMS
- `vault_ocid` — vault existente. Si vacío, se crea uno nuevo.
- `key_ocid` — key existente. Si vacío, se crea una nueva (AES-256).

#### Función de scale-in (sólo elastic)
- `scale_in_function_image` — imagen OCIR. Default: `mad.ocir.io/axp2ice0s7el/openvidu-scalein:main` (publicada por el equipo OpenVidu).

#### Avanzado
- `additionalInstallFlags` — flags extra al instalador OpenVidu, separados por coma. Regex valida caracteres permitidos.

---

## 4. Arquitectura de recursos OCI

### 4.1 Red

- `oci_core_vcn.openvidu_vcn` — CIDR `10.0.0.0/16`, DNS label derivado del `stackName`.
- `oci_core_internet_gateway.openvidu_ig` — habilitado.
- `oci_core_route_table.openvidu_rt` — ruta `0.0.0.0/0` → Internet Gateway.
- `oci_core_security_list.openvidu_subnet_security_list`:
  - Egress: all → `0.0.0.0/0`.
  - Ingress: all desde `10.0.0.0/16`.
  - **Importante**: OCI evalúa Security List **AND** NSG con lógica AND. Por eso la security list permite todo el tráfico **intra-VCN** y el filtrado fino lo hacen los NSGs por rol.
- `oci_core_subnet.openvidu_subnet` — `10.0.1.0/24`, DNS label `subnet`, asociada a la security list y route table.

### 4.2 Network Security Groups

Dos NSGs separados:

- `master_nsg`
- `media_nsg`

Reglas declaradas en `locals` y materializadas con `for_each`:

**Egress (ambos)**: todo permitido.

**Master — Ingress desde Internet (TCP)**:
| Puerto | Uso |
|--------|-----|
| 22 | SSH |
| 80 | HTTP |
| 443 | HTTPS |
| 1935 | RTMP |
| 9000 | MinIO |

**Media — Ingress desde Internet (TCP)**:
| Puerto | Uso |
|--------|-----|
| 22 | SSH |
| 7880 | LiveKit API |
| 7881 | LiveKit TCP |
| 50000–60000 | RTP TCP |

**Media — Ingress desde Internet (UDP)**:
| Puerto | Uso |
|--------|-----|
| 443 | DTLS |
| 7885 | TURN |
| 50000–60000 | RTP UDP |

**Inter-nodos** (cross-NSG, no requiere CIDR específico):

- Media → Master (TCP): 7000 (livekit), 9100 (metrics), 20000 (openvidu), 3100 (loki), 9009 (tempo), 4443 (rtc), 9080 (media_api), 6080 (kurento).
- Master → Media (TCP): 1935 (rtmp), 5349 (turn), 7880 (livekit), 8080 (api).

### 4.3 Object Storage (S3-compatible)

- `oci_identity_customer_secret_key.openvidu_s3_key` — generado para `user_ocid`. Devuelve `id` = S3 Access Key ID, `key` = S3 Secret Key (sensitive, en state).
- `oci_objectstorage_bucket.appdata_bucket` — sólo si `bucketName` está vacío. Acceso `NoPublicAccess`, sufijo aleatorio.
- Local `bucket_app_data_name` — bucket efectivo (creado o pasado por variable).
- `oci_objectstorage_object.ssh_private_key` — se sube al bucket la **private key SSH** generada por `tls_private_key.openvidu_ssh_key_elastic`. Esto permite al usuario recuperar la clave para conectarse al master/media.

OCI Object Storage se usa vía **endpoint S3-compatible**:

```
https://<namespace>.compat.objectstorage.<region>.oraclecloud.com
```

El `config_s3.sh` (ver §6.3) inyecta endpoint, region, access key, secret key y bucket en `/opt/openvidu/config/cluster/openvidu.env`.

### 4.4 KMS Vault y Key

- `oci_kms_vault.openvidu_vault` — creado sólo si `vault_ocid` está vacío. Tipo `DEFAULT`.
- `null_resource.wait_for_vault_dns` — espera (≤15 min, polling cada 5 s) a que el hostname del management endpoint del vault sea resoluble por DNS. Es necesario porque OCI marca el vault ACTIVE antes de que el DNS sea visible y eso rompe la creación de keys.
- `oci_kms_key.openvidu_key` — AES-256.
- Datasources `data.oci_kms_vault.openvidu_vault` y `data.oci_kms_key.openvidu_key` resuelven el OCID efectivo (creado o pasado por variable) para usar en políticas IAM y scripts.

### 4.5 Master Node (compute)

- Recurso: `oci_core_instance.openvidu_master_node`.
- Imagen: última Ubuntu 24.04 para el shape, descubierta vía `data.oci_core_images.ubuntu_master`.
- VNIC: pública, en la subred, con `master_nsg` adjunto.
- `user_data` = `local.user_data_master` gzipped + base64 (cloud-init).
- `freeform_tags`: `stack=<stackName>`, `node-type=master` (usado por la limpieza de huérfanos).
- Depende de `time_sleep.wait_for_iam_propagation` para garantizar que las policies estén propagadas antes de arrancar.

### 4.6 Media Nodes (Instance Configuration + Pool + Autoscaling)

- `oci_core_instance_configuration.media_node_config` — plantilla con shape, imagen Ubuntu 24.04 para media, VNIC pública, NSG media, `user_data = local.user_data_media`, y metadata extra `masterNodePrivateIP = <master IP>` para que el media descubra al master en cloud-init.
- `oci_core_instance_pool.media_node_pool` — tamaño inicial:
  - `fixedNumberOfMediaNodes` si > 0,
  - si no, `initialNumberOfMediaNodes`.
- `oci_autoscaling_auto_scaling_configuration.media_node_autoscaling` — creado sólo si `fixedNumberOfMediaNodes == 0`. Configurado con:
  - cooldown 300 s.
  - **scale-out rule**: `CPU_UTILIZATION > scaleTargetCPU` → CHANGE_COUNT_BY +1.
  - **scale-in rule no-op**: `CPU_UTILIZATION < 0` (imposible) → CHANGE_COUNT_BY -1. Existe **únicamente** para satisfacer la validación del provider (≥1 regla de scale-in), pero **nunca dispara**. **Todo el scale-in lo decide la OCI Function** (`func.py`).

### 4.7 Limpieza de huérfanos (`null_resource.cleanup_orphaned_media_nodes`)

Cuando `func.py` decide retirar un media node hace **detach** del pool (no terminate). El nodo sale del control del pool y, en condiciones normales, su `graceful_shutdown.sh` se autoterminará. Si esa secuencia falla, el nodo queda “huérfano”: ya no está en el pool, por lo que `terraform destroy` no lo conoce.

Este `null_resource` ejecuta un provisioner `local-exec when = destroy` que:

1. Lista todas las instancias con tag `stack=<stackName>` y `node-type=media` no terminadas.
2. Lista los miembros actuales del pool.
3. Calcula la diferencia (orphans = ALL − MEMBERS).
4. Llama `oci compute instance terminate --preserve-boot-volume true --force` a cada huérfano.
5. Espera a estado `TERMINATED` (timeout 10 min).
6. Limpia boot volumes huérfanos (cualquier BV `AVAILABLE` cuyo nombre contenga `<stackName>-media-pool`).

POSIX puro (sh + jq), tolerante a falta de `oci` CLI (warn + skip).

### 4.8 IAM — Pre-drain de instancias

- `oci_identity_dynamic_group.openvidu_instances_dg` — todas las instancias del compartment.
- `oci_identity_policy.media_node_predrain_policy` — creada **a nivel root** (necesario si el vault está en otro compartment). Concede al dynamic group:
  - `manage instance-pools` (para listar miembros).
  - `manage instances`, `{INSTANCE_INSPECT, READ, UPDATE, DELETE}`, `manage boot-volumes`.
  - `use vnics`, `use subnets` (necesarios para detach de VNIC al terminate).
  - `manage secret-family`, `read secret-bundles` (vault).
  - `read metrics`.
  - `use vaults`, `use keys` en el compartment del vault (puede ser distinto).
  - `use fn-invocation`, `use fn-function` (para invocar la función de scale-in).

### 4.9 IAM — OCI Function de scale-in

- `oci_identity_dynamic_group.scale_in_fn_dg` — match `resource.type='fnfunc'` en el compartment.
- `oci_identity_policy.scale_in_fn_policy`:
  - `manage instance-pools`, `manage instances`, `manage volume-family` (volume-family es necesario porque la función termina con `preserve_boot_volume=false`).
  - `read metrics`.

### 4.10 OCI Function (`scale_in_app` + `scale_in_fn` + logs)

Solo si `fixedNumberOfMediaNodes == 0`:

- `oci_functions_application.scale_in_app` — adjunta la función a la subred. Inyecta config en runtime: `COMPARTMENT_ID`, `POOL_DISPLAY_NAME`, `MIN_NODES`, `CPU_THRESHOLD`. Cambiar estas vars no requiere rebuild de la imagen.
- `oci_functions_function.scale_in_fn` — imagen `var.scale_in_function_image`, 256 MB de memoria, timeout 120 s.
- `oci_logging_log_group.scale_in_log_group` + `oci_logging_log.scale_in_fn_log` — captura stdout/stderr de la función. Retención 30 días.

### 4.11 Propagación IAM

`time_sleep.wait_for_iam_propagation` — espera 120 s tras crear el dynamic group + policy y antes de arrancar el master, porque la propagación de policies en OCI puede tardar 60–120 s y si el master arranca antes el `instance_principal` aún no tiene permisos.

---

## 5. Despliegue: cloud-init del **Master Node**

`local.user_data_master` es un script bash extenso embebido en Terraform vía heredocs. Estructura:

1. **Detección de reboot vs primer arranque** mediante el flag-file `/usr/local/bin/openvidu_install_counter.txt`.
2. **Primer arranque**:
   1. Volcar a `/usr/local/bin/` los scripts: `restart.sh`, `install.sh`, `after_install.sh`, `oci_helpers.sh`, `update_config_from_secret.sh`, `update_secret_from_config.sh`, `get_value_from_config.sh`, `store_secret.sh`, `check_app_ready.sh`, `config_s3.sh`.
   2. `apt-get install` curl, jq, wget, openssl, pipx.
   3. Instalar `oci-cli==3.83.0` vía pipx en `/root/.local/bin`.
   4. Ejecutar `install.sh` (ver §6.4).
   5. Ejecutar `config_s3.sh` (ver §6.3).
   6. `systemctl start openvidu`.
   7. Ejecutar `after_install.sh` (ver §6.5).
   8. (sólo elastic) Crear `invoke_scalein.sh` que invoca la función de scale-in con body vacío.
   9. Crear `cleanup_boot_volumes.sh` (elimina BVs huérfanos del pool detectados como DETACHED).
   10. Programar crontab:
       - `@reboot /usr/local/bin/restart.sh` → recupera el servicio tras un reinicio (refrescando config desde vault).
       - (elastic) `*/5 * * * * /usr/local/bin/invoke_scalein.sh` → llama a `func.py` cada 5 min.
       - `*/5 * * * * /usr/local/bin/cleanup_boot_volumes.sh` → limpia BVs huérfanos.
   11. Marcar instalación completa.
3. **Reboot**: ejecuta `restart.sh`, que para `openvidu`, refresca `openvidu.env` desde el vault y lo reinicia.
4. Al final, `check_app_ready.sh` espera al health check de Caddy (`http://localhost:7880/health/caddy`) y, tras 10 fallos consecutivos, reinicia el servicio.

### 5.1 `firewalld` en el master

El instalador OpenVidu configura `firewalld` y abre:

- Intra-VCN: `10.0.0.0/16` en zona `trusted`.
- Internet (TCP): 22, 80, 443, 1935, 9000.

Las reglas se persisten con `firewall-cmd --runtime-to-permanent`.

---

## 6. Scripts auxiliares en el Master

Todos están definidos en `locals` y se materializan en `/usr/local/bin/` durante cloud-init.

### 6.1 `oci_helpers.sh`
Funciones POSIX-bash reutilizables para hablar con el vault:

- `oci_with_retry` — wrap con timeout 45 s, 3 reintentos, backoff exponencial. **No usa el retry interno del CLI** porque puede colgar ~10 min en 429/5xx.
- `ocid_from_query` — filtra el string `"Query returned empty result..."` que el CLI imprime cuando JMESPath no matchea.
- `get_from_vault <name>` — lee secret ACTIVE, decodifica base64.
- `store_in_vault <name> <value>`:
  - Fast path: si existe ACTIVE → `update-base64`.
  - Si PENDING_DELETION → cancela y espera ACTIVE → update.
  - Si no existe → crea con `KEY_ID` (la create requiere KMS key).
  - Diseñado para mantenerse por debajo del rate limit del vault (30/min).

### 6.2 `store_secret.sh`
Wrapper de `oci_helpers.sh`. Tres modos:

- `generate NAME [PREFIX] [LEN]` — genera password aleatorio (openssl rand 64, base64, recortado), lo guarda y lo escupe a stdout.
- `save NAME VALUE` — guarda y escupe el valor.
- `get NAME` — recupera el valor desde el vault.

Usado por el `install.sh` del master para generar/guardar todos los secretos.

### 6.3 `config_s3.sh`
Edita `/opt/openvidu/config/cluster/openvidu.env`:

```
EXTERNAL_S3_ENDPOINT=https://<namespace>.compat.objectstorage.<region>.oraclecloud.com
EXTERNAL_S3_REGION=<region>
EXTERNAL_S3_PATH_STYLE_ACCESS=true
EXTERNAL_S3_BUCKET_APP_DATA=<bucket>
EXTERNAL_S3_ACCESS_KEY=<customer secret key id>
EXTERNAL_S3_SECRET_KEY=<customer secret key>
```

### 6.4 `install.sh` (Master)
1. `apt-get install` paquetes base + `firewalld`.
2. Configura `firewalld` (ver §5.1).
3. Descarga `yq` (arquitectura amd64 o arm64 según el shape; los sha256 están baked-in).
4. `store_secret.sh save ALL_SECRETS_GENERATED false` — marca como “no listo” para que media nodes de despliegues anteriores no lean valores stale.
5. Resuelve la IP pública (IMDS v2 → opendns → ipify).
6. Calcula dominio: `var.domainName` o `openvidu-<random>-<ip-con-guiones>.sslip.io`.
7. Guarda en vault:
   - `DOMAIN_NAME`, `MEET_INITIAL_ADMIN_USER`, `MEET_INITIAL_ADMIN_PASSWORD` (provisto o generado), `MEET_INITIAL_API_KEY` (sólo si provisto).
   - `REDIS_PASSWORD` (gen), `MONGO_ADMIN_USERNAME=mongoadmin`, `MONGO_ADMIN_PASSWORD` (gen), `MONGO_REPLICA_SET_KEY` (gen).
   - `MINIO_ACCESS_KEY=minioadmin`, `MINIO_SECRET_KEY` (gen).
   - `DASHBOARD_ADMIN_USERNAME=dashboardadmin`, `DASHBOARD_ADMIN_PASSWORD` (gen).
   - `GRAFANA_ADMIN_USERNAME=grafanaadmin`, `GRAFANA_ADMIN_PASSWORD` (gen).
   - `ENABLED_MODULES=observability,openviduMeet,v2compatibility`.
   - `LIVEKIT_API_KEY` (prefijo `API`, 12 chars), `LIVEKIT_API_SECRET` (gen).
   - `OPENVIDU_PRO_LICENSE`, `OPENVIDU_RTC_ENGINE`, `OPENVIDU_VERSION=main`.
   - `ALL_SECRETS_GENERATED=true` — gatillo para los media nodes.
8. Construye comando de instalación:
   ```
   sh <(curl -fsSL http://get.openvidu.io/pro/elastic/<version>/install_ov_master_node.sh) \
     --no-tty --install --environment=oracle --deployment-type=elastic --node-role=master-node \
     --openvidu-pro-license=... --private-ip=... --domain-name=... --enabled-modules='...' \
     --rtc-engine=... --redis-password=... --mongo-admin-user=... --mongo-admin-password=... \
     --mongo-replica-set-key=... --minio-access-key=... --minio-secret-key=... \
     --dashboard-admin-user=... --dashboard-admin-password=... \
     --grafana-admin-user=... --grafana-admin-password=... \
     --meet-initial-admin-password=... [--meet-initial-api-key=...] \
     --livekit-api-key=... --livekit-api-secret=... \
     [--additional-flags...] \
     --certificate-type={letsencrypt|selfsigned|owncert} [--owncert-public-key=... --owncert-private-key=...]
   ```
9. `exec bash -c "$FINAL_COMMAND"`.

### 6.5 `after_install.sh`
Construye las URLs derivadas y las guarda en el vault:
- `OPENVIDU_URL=https://$DOMAIN/`
- `LIVEKIT_URL=wss://$DOMAIN/`
- `DASHBOARD_URL=https://$DOMAIN/dashboard/`
- `GRAFANA_URL=https://$DOMAIN/grafana/`
- `MINIO_URL=https://$DOMAIN/minio-console/`

### 6.6 `update_config_from_secret.sh`
Lee todos los secretos del vault y los inyecta vía `sed -i` en:
- `/opt/openvidu/config/cluster/openvidu.env`
- `/opt/openvidu/config/node/master_node.env`
- `/opt/openvidu/config/cluster/master_node/meet.env`

También recalcula y guarda las URL secrets (idempotente).

### 6.7 `update_secret_from_config.sh`
Camino inverso: para cada clave, lee el valor actual del config y lo sube al vault. La función `maybe_save` salta valores vacíos o literal `none` para no corromper el secret.

### 6.8 `get_value_from_config.sh`
Lee un `KEY=VAL` (con o sin espacios, ignorando comentarios) de un archivo dado. Devuelve `none` si no hay valor.

### 6.9 `check_app_ready.sh`
Hace polling cada 5 s a `http://localhost:7880/health/caddy`. Tras 10 fallos consecutivos, `systemctl restart openvidu` (auto-recovery del control plane).

### 6.10 `restart.sh` (ejecutado en `@reboot`)
`systemctl stop openvidu` → `update_config_from_secret.sh` → `systemctl start openvidu`. Garantiza que tras reinicio del VM (manual o por OCI) los servicios arrancan con la config refrescada desde el vault.

### 6.11 `invoke_scalein.sh` (sólo elastic)
Invoca la función con body vacío y auth `instance_principal`. Ejecutado por cron `*/5 * * * *`.

### 6.12 `cleanup_boot_volumes.sh`
Cada 5 min. Lista BVs `AVAILABLE` que contengan el prefijo del pool y, si no hay attachments activos (≠ DETACHED/DETACHING), los borra. Compensa eventos donde una instancia se autotermina pero su BV queda colgando porque su `preserve_boot_volume` fue inconsistente.

---

## 7. Despliegue: cloud-init del **Media Node**

`local.user_data_media` se ejecuta en cada nueva instancia del pool. Pasos:

1. Instalar deps + `pipx` + `oci-cli==3.83.0`.
2. Volcar `/etc/openvidu/predrain.conf` con `COMPARTMENT_ID` y `POOL_DISPLAY_NAME`.
3. Volcar `/usr/local/bin/install.sh` (versión media; ver §7.1).
4. (sólo elastic) Configurar el sistema de drenado en dos capas (ver §8).
5. Ejecutar `install.sh`.
6. `systemctl start openvidu`.
7. Marcar instalación completa.
8. (sólo elastic) Arrancar `openvidu-pre-drain.service`.

### 7.1 `install.sh` (Media)

1. Instalar firewalld y abrir puertos:
   - Intra-VCN: `10.0.0.0/16` trusted.
   - Internet TCP: 22, 7880, 7881, 50000–60000.
   - Internet UDP: 443, 7885, 50000–60000.
2. Leer del IMDS v2: `masterNodePrivateIP` (inyectado por Terraform en `instance_configuration.metadata`) y la propia private IP.
3. Definir `get_secret()` con `oci_with_retry` + `ocid_from_query` (paralelos a `oci_helpers.sh`, copiados aquí porque el media no monta `/usr/local/bin/oci_helpers.sh`).
4. Bloquear hasta que `ALL_SECRETS_GENERATED=true` en el vault (polling cada 10 s) — sincronización con el master.
5. Leer `DOMAIN_NAME`, `OPENVIDU_PRO_LICENSE`, `REDIS_PASSWORD`, `OPENVIDU_VERSION` del vault.
6. Ejecutar:
   ```
   sh <(curl -fsSL http://get.openvidu.io/pro/elastic/<version>/install_ov_media_node.sh) \
     --no-tty --install --environment=oracle --deployment-type=elastic --node-role=media-node \
     --master-node-private-ip=<master_priv_ip> --private-ip=<own_priv_ip> \
     --redis-password=<...>
   ```

---

## 8. Drenaje (graceful drain) en dos capas

Sólo se monta cuando `fixedNumberOfMediaNodes == 0`. Objetivo: **no cortar sesiones activas** durante un scale-in.

### 8.1 Capa 1 — Pre-drain Daemon (`openvidu-pre-drain.service`)

- Script: `/usr/local/bin/openvidu-pre-drain.sh` (definido en `local.pre_drain_daemon_script`).
- Modo de operación:
  1. Si existe el lock `/var/run/openvidu-drain.lock` → ya estaba drenando: queda bloqueado esperando la self-termination.
  2. Descubre su propio OCID por IMDS v2.
  3. Descubre el OCID del pool buscando por `display_name` (`<stackName>-media-pool`). Reintenta hasta éxito.
  4. **Loop cada 30 s**: lista miembros del pool y comprueba si su OCID sigue dentro.
  5. Si no está → `func.py` lo ha detached → `exec graceful_shutdown.sh`.

Esta es la **señal de scale-in**: aparecer fuera del pool. Ya no se basa en CPU local, sino en la decisión central de `func.py`.

### 8.2 Capa 2 — Systemd Shutdown (`graceful_shutdown.service`)

Fallback para cualquier escenario de poweroff (ej. `oci instance action --action SOFTSTOP` desde la consola): `DefaultDependencies=no`, `Before=shutdown.target reboot.target halt.target`, ejecuta `graceful_shutdown.sh` con `TimeoutStartSec=infinity` y `TimeoutStopSec=infinity`. Además, se sobreescribe `DefaultTimeoutStopSec=infinity` en `/etc/systemd/system.conf` para que systemd no aborte el drenaje.

### 8.3 `graceful_shutdown.sh`

1. Crea el lock `/var/run/openvidu-drain.lock` (evita doble ejecución si capa 1 y capa 2 se disparan a la vez).
2. Envía `SIGQUIT` a los contenedores Docker:
   - `openvidu`, `ingress`, `egress`.
   - Todos los con `label=openvidu-agent=true`.
   - Esto le indica a OpenVidu/LiveKit que no acepte nuevas sesiones pero termine las activas.
3. **Bucle indefinido** (sin timeout) esperando que todos esos contenedores ya no estén `Running`.
4. Obtiene su propio OCID.
5. Llama a `invoke_terminate.py <ocid>` repetidamente (cada 15 s en caso de fallo) hasta que la función acepte la petición.
6. Tras aceptación, queda en `sleep 60` infinito esperando que OCI lo termine.

### 8.4 `invoke_terminate.py`

Script Python (ejecutado con el intérprete del venv pipx del OCI CLI, que ya tiene el SDK). Necesario porque **OCI CLI 3.83 no entrega el body** de `oci fn function invoke --body '{"terminate_instance_id":...}'` correctamente — el body llega vacío a la función y cae en la rama de scale-in normal. El script:

```python
signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
mgmt   = oci.functions.FunctionsManagementClient(config={}, signer=signer)
fn     = mgmt.get_function(function_id=FN_ID).data
invoke = oci.functions.FunctionsInvokeClient(config={}, signer=signer, service_endpoint=fn.invoke_endpoint)

body = json.dumps({"terminate_instance_id": instance_ocid}).encode()
result = invoke.invoke_function(function_id=FN_ID, invoke_function_body=body)
```

### 8.5 Por qué un instance principal NO puede terminate-self directamente

Hay una **deny policy a nivel tenancy** que bloquea a `instance_principal` la operación `TerminateInstance`. La función, en cambio, autentica con **Resource Principal**, que no está sujeta a esa deny. Por eso la self-termination se hace **delegando** en la función (que valida la identidad del caller; ver §9.1).

---

## 9. OCI Function `openvidu-scalein` (`pro/scalein-function/`)

### 9.1 `func.py` — entrypoint `handler(ctx, data)`

Parsea el body. Dos modos:

- Si el JSON contiene `terminate_instance_id` → `_handle_terminate`.
- Si no → `_evaluate_scale_in`.

#### `_handle_terminate(instance_id)` — modo terminate

- Lee headers inyectados por OCI Functions:
  - `oci-subject-type` (= `instance` si el caller es un media node).
  - `oci-subject-id` (= OCID del caller).
- **Verifica**:
  - `caller_type == "instance"`, si no → 403 `caller_not_instance`.
  - `caller_id == instance_id`, si no → 403 `caller_target_mismatch`.
- Sólo entonces ejecuta `compute.terminate_instance(instance_id, preserve_boot_volume=False)`.
- Devuelve `{action: "terminated", instance_id}`.

**Modelo de identidad**: un nodo sólo puede pedir terminar **a sí mismo**. Estos headers los inyecta el servicio de OCI Functions tras validar la firma, no se pueden falsificar desde el caller.

#### `_evaluate_scale_in()` — modo scale-in eval

Invocado por el cron del master cada 5 min con body vacío.

1. Lee env vars `COMPARTMENT_ID`, `POOL_DISPLAY_NAME`, `MIN_NODES`, `CPU_THRESHOLD`.
2. Busca el pool por `display_name` en estado `RUNNING`. Si no existe → `noop:pool_not_found`.
3. Lee `pool_detail.size`. Si `<= MIN_NODES` → `noop:at_minimum`.
4. Lista miembros `Running`, ordenados por `time_created` ascendente.
5. Si algún miembro está dentro del **GRACE_MINUTES = 7** desde su creación → `noop:grace_period`. Esto evita que un nodo recién creado (CPU baja por estar frío) tire el promedio y dispare un scale-in en cadena.
6. Calcula CPU media (5-min mean) por miembro vía `oci.monitoring`:
   ```
   query = f'CpuUtilization[1m]{{resourceId="{instance_id}"}}.mean()'
   namespace = "oci_computeagent"
   ```
   Si alguno no tiene métricas → `noop:metrics_unavailable` (fail-safe; no se asume CPU baja por defecto).
7. Si `avg(cpu) >= CPU_THRESHOLD` → `noop:cpu_above_threshold`.
8. Si `avg(cpu) < CPU_THRESHOLD` → **detach** del más antiguo con:
   ```
   detach_instance_pool_instance(
     instance_pool_id=pool.id,
     ...DetachInstancePoolInstanceDetails(
        instance_id=target.id,
        is_decrement_size=True,
        is_auto_terminate=False,
     ),
   )
   ```
   - `is_decrement_size=True` → el pool reduce target en 1, no spawnea reemplazo.
   - `is_auto_terminate=False` → OCI **no** termina la instancia (la deja viva fuera del pool para que se drene).
9. Devuelve `{action: "scale_in", instance_id, display_name, pool_avg_cpu, threshold}`.

### 9.2 `Dockerfile`

Multi-stage:

1. `fnproject/python:3.11-dev` → `pip install --target /python/packages -r requirements.txt`.
2. **Purga** del SDK OCI: deja sólo `_vendor, auth, circuit_breaker, core, dns, monitoring, object_storage, pagination, retry, work_requests`. El resto se borra. Ahorro ~430 MB.
3. Borra `__pycache__` y `*.pyc`.
4. Stage final `fnproject/python:3.11`, copia paquetes y código, `PYTHONPATH=/python/packages`, `ENTRYPOINT ["/python/packages/bin/fdk", "/function/func.py", "handler"]`.

### 9.3 `build-and-push.sh`

Pipeline manual de publicación. Pasos:

1. Escaneo de fuentes contra patrones de secretos (OCIDs reales, claves privadas, asignaciones `password/secret/token/api_key`, Bearer largos, AWS access keys). Líneas marcadas con `# noqa: secret-scan` se exceptúan.
2. `docker build --no-cache`.
3. Escaneo de filesystem de la imagen: rutas sospechosas (`/root/.oci`, `*.pem`, `id_rsa`, ...) y patrones en `/function` (se excluye `/python/packages` porque el SDK contiene ejemplos OCID y claves PEM en docstrings legítimos).
4. Verifica que el `ENTRYPOINT` contiene `fdk` y que el binario existe.
5. Inspecciona ENV de la imagen — no debe haber `password|secret|token|key|ocid` (`PYTHONPATH` exceptuado).
6. `docker push`.

Falla rápido con conteo de issues; si hay alguno, **borra la imagen local y no la publica**.

---

## 10. Flujo end-to-end del scale-in

```
[cron @master cada 5 min]
        │
        ▼
invoke_scalein.sh (oci fn function invoke --body '')
        │
        ▼
─ OCI Function (Resource Principal) ───────────────────────────────
│ func.py._evaluate_scale_in()                                    │
│  • pool por display_name, size > MIN_NODES                      │
│  • ningún miembro dentro del grace period (7 min)               │
│  • avg(CPU_5min) < CPU_THRESHOLD                                │
│  → detach_instance_pool_instance(                               │
│       oldest, is_decrement_size=True, is_auto_terminate=False)  │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼ (instancia ya no aparece en list_instance_pool_instances)
[Pre-drain daemon @media node detecta detach]
        │
        ▼
exec graceful_shutdown.sh
        │  • lock /var/run/openvidu-drain.lock
        │  • docker kill --signal=SIGQUIT openvidu ingress egress + agents
        │  • loop hasta que TODOS los contenedores estén stopped (sin timeout)
        ▼
invoke_terminate.py <instance_ocid>  (Python SDK directo)
        │
        ▼
─ OCI Function (Resource Principal) ───────────────────────────────
│ func.py._handle_terminate(instance_id)                          │
│  • verifica oci-subject-type == "instance"                      │
│  • verifica oci-subject-id   == terminate_instance_id           │
│  → compute.terminate_instance(id, preserve_boot_volume=False)   │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
[OCI termina la instancia + el boot volume]
[cleanup_boot_volumes.sh @master borra cualquier BV residual]
```

---

## 11. Flujo end-to-end del scale-out

```
[OCI Monitoring observa CPU pool-wide]
        │
        ▼
[oci_autoscaling_auto_scaling_configuration]
   policy "scale-out-rule": CpuUtilization > scaleTargetCPU
        │
        ▼
+1 a instance pool target
        │
        ▼
[Pool lanza nueva instancia con oci_core_instance_configuration]
        │
        ▼
cloud-init media:
   • instala deps + oci-cli
   • escribe /etc/openvidu/predrain.conf
   • instala scripts de drenaje
   • install.sh espera ALL_SECRETS_GENERATED=true en vault
   • install_ov_media_node.sh --master-node-private-ip=... ...
   • systemctl start openvidu
   • systemctl start openvidu-pre-drain.service
        │
        ▼
[Nuevo media node operativo]
        │
        ▼ (~7 min después)
[func.py vuelve a considerarlo para futuros scale-in]
```

---

## 12. Gestión de secretos: dos sentidos vault ⇆ filesystem

- **vault → filesystem** (`update_config_from_secret.sh`): se usa en `@reboot` (vía `restart.sh`) y al añadir nodos. Garantiza que la realidad del filesystem refleja la verdad del vault.
- **filesystem → vault** (`update_secret_from_config.sh`): permite recoger cambios hechos manualmente en `openvidu.env` y promoverlos al vault para que sobrevivan a un reboot y los media nodes nuevos los hereden.

El acceso al vault es siempre vía **Instance Principal**, sin credenciales en disco. Todas las llamadas pasan por `oci_with_retry` + `OCI_CLI_DISABLE_DEFAULT_RETRY=True` para que el control de reintentos sea propio (3 intentos, timeout 45 s c/u, backoff exponencial 5 → 10 → 20 s).

---

## 13. Sincronización Master ⇄ Media

El “handshake” inicial entre master y media se hace **a través del vault**, no por red directa:

1. Master arranca, `install.sh` setea `ALL_SECRETS_GENERATED=false` antes de generar nada.
2. Master genera y guarda todos los secretos en el vault.
3. Master pone `ALL_SECRETS_GENERATED=true`.
4. Media node (al arrancar) hace polling cada 10 s: `until get_secret ALL_SECRETS_GENERATED == "true"`.
5. Cuando lo ve `true`, lee `DOMAIN_NAME`, `OPENVIDU_PRO_LICENSE`, `REDIS_PASSWORD`, `OPENVIDU_VERSION` y procede con `install_ov_media_node.sh`.

Esto evita race conditions cuando el pool spawnea miembros antes de que el master termine de instalar (caso típico al apuntar `initialNumberOfMediaNodes > 1`).

---

## 14. Outputs

`output.tf` no expone secretos. Sólo imprime un mensaje guía para que el usuario conecte por SSH al master y obtenga las credenciales reales desde el vault (recomendación apuntada por la doc oficial: https://openvidu.io/latest/docs/self-hosting/elastic/oracle/install/).

La SSH private key se guarda en el bucket de Object Storage como `<stackName>-private-key.pem` (objeto privado, `NoPublicAccess`).

---

## 15. Limitaciones y notas operativas

- **No HA**: el master es un único punto de fallo. Para HA usar el módulo `pro/ha/`.
- **No multi-AD**: todas las instancias del pool van al mismo Availability Domain (`availability_domain`).
- **`oci-cli==3.83.0`**: versión pineada porque el bug de `fn function invoke --body` se workaround vía `invoke_terminate.py`. Subir CLI requiere re-testear.
- **Rate limit del vault**: 30 ops/min. `store_in_vault` tiene fast-path para no llamar `cancel-secret-deletion` en cada update.
- **Función publicada por OpenVidu**: por defecto se usa `mad.ocir.io/axp2ice0s7el/openvidu-scalein:main`. Mirroring → ver `build-and-push.sh`.
- **DNS del vault**: ~30–900 s de espera tras crear el vault antes de que el management endpoint sea resoluble. Manejado por `null_resource.wait_for_vault_dns`.
- **Propagación IAM**: 120 s antes de arrancar el master para que `instance_principal` tenga permisos consolidados.
- **`destroy`**: garantiza limpieza de orphans (`cleanup_orphaned_media_nodes`) + boot volumes huérfanos. Requiere `oci` CLI en el `$PATH` del host que ejecuta Terraform; sin él, warn + skip.
- **ARM (Ampere)**: soportado. Si `masterNodeShape` empieza por `VM.Standard.A` o `BM.Standard.A`, se descarga la build arm64 de `yq` con el sha256 correspondiente. Los media nodes usan el mismo árbol de detección.
- **Modo fijo**: `fixedNumberOfMediaNodes > 0` salta toda la rama de autoscaling, función, dynamic group de la función, policy de la función, logs y scripts de drenaje. Pool simple, sin elasticidad.

---

## 16. Mapa de archivos generados en runtime

En el Master (`/usr/local/bin/`):
- `restart.sh`, `install.sh`, `after_install.sh`
- `oci_helpers.sh`, `store_secret.sh`
- `update_config_from_secret.sh`, `update_secret_from_config.sh`, `get_value_from_config.sh`
- `check_app_ready.sh`, `config_s3.sh`
- `invoke_scalein.sh` (sólo elastic)
- `cleanup_boot_volumes.sh`
- `openvidu_install_counter.txt` (flag de install completo)

En el Media (`/usr/local/bin/`):
- `install.sh`
- `openvidu-pre-drain.sh`, `graceful_shutdown.sh`, `invoke_terminate.py` (sólo elastic)
- `openvidu_install_counter.txt`

Configs:
- `/etc/openvidu/predrain.conf` (media, elastic)
- `/etc/systemd/system/openvidu-pre-drain.service` (media, elastic)
- `/etc/systemd/system/graceful_shutdown.service` (media, elastic)
- `/opt/openvidu/config/...` (creados por el instalador OpenVidu)

Locks/estado:
- `/var/run/openvidu-drain.lock`

Logs:
- `/var/log/openvidu-restart.log` (cron `@reboot`)
- `/var/log/openvidu-cleanup-bv.log` (cron `*/5`)
- journal: `openvidu-pre-drain.service`, `graceful_shutdown.service`

---

## 17. Diagrama lógico

```
                       ┌──────────────────────────────┐
                       │            Internet          │
                       └───────────────┬──────────────┘
                                       │
                              Internet Gateway
                                       │
                              VCN 10.0.0.0/16
                                       │
                              Subnet 10.0.1.0/24
                          ┌────────────┴───────────────┐
                          │                            │
                    master_nsg                    media_nsg
                          │                            │
                  ┌───────▼────────┐         ┌─────────▼──────────┐
                  │  Master Node   │◀───────▶│  Instance Pool     │
                  │  (Ubuntu 24.04)│  intra  │  size: [min..max]  │
                  │  - Caddy       │   VCN   │  Media Nodes       │
                  │  - openvidu    │         │  - LiveKit         │
                  │  - Redis/Mongo │         │  - ingress/egress  │
                  │  - MinIO       │         │  - pre-drain svc   │
                  │  - Grafana     │         └────────────────────┘
                  │  - Meet        │                  ▲
                  │  - cron 5min   │                  │
                  └─┬────┬─────────┘                  │
                    │    │                            │
                    │    ▼                            │
                    │  ┌────────────────────────┐     │
                    │  │ OCI Function           │─────┘  (detach + terminate)
                    │  │ openvidu-scalein       │
                    │  │ (Resource Principal)   │
                    │  └────────────┬───────────┘
                    │               │
                    │      ┌────────▼──────────┐
                    │      │ OCI Monitoring    │
                    │      │ CpuUtilization    │
                    │      └───────────────────┘
                    │
        ┌───────────┴───────────┬───────────────────────────┐
        ▼                       ▼                           ▼
 ┌─────────────┐        ┌────────────────┐         ┌──────────────────┐
 │ OCI KMS     │        │ Object Storage │         │ Autoscaling Cfg  │
 │ Vault + Key │        │ (S3-compat)    │         │ scale-out: CPU>T │
 │ secretos    │        │ appdata bucket │         │ scale-in:  noop  │
 └─────────────┘        │ + ssh private  │         └──────────────────┘
                        └────────────────┘
```

---

## 18. Referencias rápidas

- Doc oficial usuario: https://openvidu.io/latest/docs/self-hosting/elastic/oracle/install/
- Imagen función por defecto: `mad.ocir.io/axp2ice0s7el/openvidu-scalein:main`
- Endpoint S3 OCI: `https://<ns>.compat.objectstorage.<region>.oraclecloud.com`
- IMDS v2: `http://169.254.169.254/opc/v2/instance/`
- Repo: https://github.com/OpenVidu/openvidu-oracle
