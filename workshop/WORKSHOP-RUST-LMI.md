# Workshop: Lambda Managed Instances con Rust

## Descripción General

Este workshop te guía paso a paso para desplegar funciones Lambda sobre **Lambda Managed Instances (LMI)** usando **Rust**. LMI ejecuta tus funciones en instancias EC2 gestionadas por Lambda con multi-concurrencia, sin cold starts y con pricing de EC2.

### ¿Por qué Rust en LMI?

- Rust compila a código nativo, ejecutándose como custom runtime (`provided.al2023`)
- En LMI, Rust usa un único proceso con **async tasks de Tokio**, alcanzando hasta **8 requests concurrentes por vCPU** (por defecto)
- Sin garbage collector, latencia predecible y mínimo uso de memoria
- Los clientes del AWS SDK para Rust son concurrency-safe sin configuración adicional

### Requisitos previos

| Herramienta | Versión mínima |
|---|---|
| Rust | 1.84.0 (MSRV para LMI) |
| `cargo-lambda` | Última versión |
| AWS CLI | v2 |
| Cuenta AWS | Con permisos para Lambda, EC2, IAM, VPC |

### Instalar herramientas

```bash
# Instalar Rust (si no lo tienes)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

# Instalar cargo-lambda
cargo install cargo-lambda

# Verificar versiones
rustc --version
cargo lambda --version
aws --version
```

---

## Módulo 1: Cuándo usar Lambda Managed Instances

Antes de crear tu primera función LMI, decide si es la opción correcta para tu caso de uso.

### Tabla de decisión rápida

| Carga de trabajo | ¿Usar LMI? | Razón |
|---|---|---|
| Tráfico alto y constante (>50 req/s sostenido) | ✅ Sí | Multi-concurrencia maximiza el uso de vCPU |
| CPU o memoria intensiva (>1 GB, larga duración) | ✅ Sí | Instancias dedicadas con tipos configurables |
| Tráfico predecible, sensible a latencia | ✅ Sí | Ambientes pre-calentados, sin cold starts |
| Jobs de larga duración (>15 min, async o batch) | ✅ Sí | Timeout de hasta 90 minutos |
| Carga constante sensible al costo | ✅ Sí | Pricing EC2 con Savings Plans y RIs |
| Invocaciones esporádicas o bursty | ❌ No | Lambda estándar escala a cero |
| Eventos de bajo volumen (S3, SQS) | ❌ No | Pricing por request es más económico |

### Comparativa: Lambda Estándar vs LMI

|  | Lambda Estándar | Lambda Managed Instances |
|---|---|---|
| **Concurrencia** | 1 request por ambiente de ejecución | Múltiples requests por ambiente (hasta 8/vCPU en Rust) |
| **Escalado** | Escala al llegar invocaciones (cold starts) | Escala por utilización de CPU (sin cold starts) |
| **Pricing** | Por request + duración | Requests ($0.20/millón) + horas EC2 + 15% management fee |
| **Escala a cero** | Sí | No — mínimo 3 instancias siempre corriendo |
| **Aislamiento** | Firecracker microVMs | Contenedores en instancias EC2 Nitro |
| **Control de instancia** | Ninguno | Elige familia (C, M, R) y arquitectura |

### Multi-concurrencia por runtime

| Lenguaje | Concurrencia por defecto por vCPU | Mecanismo |
|---|---|---|
| Node.js | 64 | Worker threads + async |
| Java | 32 | OS threads |
| .NET | 32 | Tasks async |
| Python | 16 | Múltiples procesos |
| **Rust** | **8** | **Async tasks con Tokio** |

---

## Módulo 2: Crear el Capacity Provider

Un **Capacity Provider** es la base para ejecutar Lambda Managed Instances. Define la infraestructura de cómputo (VPC, subredes, tipos de instancia y comportamiento de escalado).

### Flujo de 3 pasos

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│  1. Crear Capacity  │────▶│  2. Desplegar       │────▶│  3. Publicar        │
│     Provider        │     │     Función         │     │     Versión         │
└─────────────────────┘     └─────────────────────┘     └─────────────────────┘
   Infraestructura            Código + Config             Lanza instancias EC2
```

### Componentes pre-aprovisionados

Antes de crear el capacity provider necesitas:

- **VPC con subredes privadas**: 3 subredes en diferentes AZs con NAT Gateway
- **Security group**: Solo egress, permitiendo a tus funciones alcanzar servicios AWS
- **Operator role**: Rol IAM con la política `AWSLambdaManagedEC2ResourceOperator`

### Opción recomendada: `setup-capacity-provider.sh`

El script cubre los tres pasos de este módulo de una vez: descubre VPC, subredes y roles en tu cuenta (buscando el tag `*LMI*`), valida el formato de cada ID, pide confirmación, crea el capacity provider, espera a que pase a `Active` y guarda todo en `workshop/.env`:

```bash
bash workshop/setup-capacity-provider.sh
```

Al terminar, `workshop/.env` contiene `VPC_ID`, `SUBNET_IDS`, `SECURITY_GROUP_ID`, `OPERATOR_ROLE_ARN`, `EXECUTION_ROLE_ARN` y `CP_ARN`. El resto de los scripts leen ese archivo, así que este módulo es prerequisito de todo lo que sigue.

> El script **reescribe** el `.env` desde cero al guardar. Si vuelves a ejecutarlo después de haber desplegado, perderás `LMI_VERSION` y `TENANT_B_VERSION`.

Los pasos manuales que siguen son el equivalente de lo que hace el script, por si prefieres ejecutarlos uno a uno.

### Paso 2.1: Verificar variables de entorno

```bash
echo "VPC: $VPC_ID"
echo "Subnets: $SUBNET_IDS"
echo "Security Group: $SECURITY_GROUP_ID"
echo "Operator Role: $OPERATOR_ROLE_ARN"
```

Todos los valores deben estar poblados. Si alguno está vacío, ejecuta los exports del paso de Getting Started.

### Paso 2.2: Crear el Capacity Provider

```bash
aws lambda create-capacity-provider \
  --capacity-provider-name lmi-workshop-capacity-provider \
  --vpc-config "SubnetIds=[$SUBNET_IDS],SecurityGroupIds=[$SECURITY_GROUP_ID]" \
  --permissions-config "CapacityProviderOperatorRoleArn=$OPERATOR_ROLE_ARN" \
  --instance-requirements "Architectures=[arm64]" \
  --capacity-provider-scaling-config "MaxVCpuCount=30"
```

Deberías ver un output con `"State": "Pending"`:

```json
{
    "CapacityProvider": {
        "CapacityProviderArn": "arn:aws:lambda:us-east-1:123456789012:capacity-provider:lmi-workshop-capacity-provider",
        "State": "Pending",
        "VpcConfig": {
            "SubnetIds": ["subnet-aaa", "subnet-bbb", "subnet-ccc"],
            "SecurityGroupIds": ["sg-xxx"]
        },
        "PermissionsConfig": {
            "CapacityProviderOperatorRoleArn": "arn:aws:iam::123456789012:role/LMIWorkshopOperatorRole"
        },
        "InstanceRequirements": {
            "Architectures": ["arm64"]
        },
        "CapacityProviderScalingConfig": {
            "MaxVCpuCount": 30,
            "ScalingMode": "Auto"
        }
    }
}
```

### Paso 2.3: Verificar que está activo

```bash
aws lambda get-capacity-provider \
  --capacity-provider-name lmi-workshop-capacity-provider \
  --query "CapacityProvider.State" \
  --output text
```

Resultado esperado: `Active` (normalmente 30-60 segundos).

### Configuración del Capacity Provider

| Setting | Valor | Razón |
|---|---|---|
| Subnets | 3 subredes privadas en diferentes AZs | Alta disponibilidad |
| Security group | Solo egress | Funciones acceden a servicios AWS, sin tráfico inbound |
| Architecture | arm64 (Graviton) | Mejor relación precio/rendimiento. x86_64 también soportada |
| Instance types | Default (Lambda elige) | Recomendado para disponibilidad |
| Max vCPUs | 30 | Límite de cómputo para controlar costos durante el workshop |

### Selección de tipos de instancia

No eliges tipos de instancia directamente. Lambda elige los óptimos según tu configuración:

| Ratio | Memoria por vCPU | Ideal para |
|---|---|---|
| 2:1 | 2 GB | Trabajo intensivo en CPU (encoding, cálculos) |
| 4:1 | 4 GB | Cargas balanceadas (APIs, web apps) |
| 8:1 | 8 GB | Trabajo intensivo en memoria (caching, ML inference) |

#### Instancias observadas en producción

Con `ExecutionEnvironmentMemoryGiBPerVCpu=2.0` y `Architectures=[arm64]`, Lambda seleccionó una mezcla de instancias durante las pruebas de carga:

| Instancia | Familia | vCPUs | Memoria | Ratio |
|---|---|---|---|---|
| c9g.2xlarge | Compute-optimized | 8 | 16 GB | 2:1 |
| c9g.4xlarge | Compute-optimized | 16 | 32 GB | 2:1 |
| m9g.xlarge | General-purpose | 4 | 16 GB | 4:1 |

Lambda eligió mayoritariamente **c9g** (compute-optimized), coherente con el ratio 2:1 configurado. El **m9g.xlarge** (ratio 4:1) fue agregado durante el scaling para llenar capacidad rápido, priorizando disponibilidad sobre match exacto de ratio.

> **Implicación para memoria**: Las invocaciones en m9g.xlarge (4 GB/vCPU) tienen más holgura de memoria que las de c9g (2 GB/vCPU). Esto explica por qué errores `Runtime.OutOfMemory` aparecen de forma intermitente bajo carga alta — depende de en qué tipo de instancia Lambda colocó la invocación.

> **Nota**: No hay instancias EC2 corriendo aún. Lambda solo lanza instancias cuando publicas una versión de función.

---

## Módulo 3: La Función en Rust

La carga de trabajo es un **procesador de datos de vuelos** que analiza CSVs con Polars: un caso realista que aprovecha las capacidades multi-vCPU de LMI, la compilación nativa de Rust y el paralelismo automático de Polars en operaciones columnares.

### El código fuente

La función completa ya está en el repositorio, en un solo archivo. No hay que escribir nada: el Módulo 4 compila y despliega ese código tal cual. Esta sección explica qué contiene y por qué.

| Archivo | Contenido |
|---|---|
| [`rust-function/Cargo.toml`](rust-function/Cargo.toml) | Dependencias y perfil de release |
| [`rust-function/src/main.rs`](rust-function/src/main.rs) | Handler, generador de datos sintéticos y las tres etapas de análisis (~410 líneas) |

> El crate se llama `lmi-workshop-function`, pero la función que se despliega en AWS es **`lmi-workshop-rust-function`**. De ahí que el zip salga en `target/lambda/lmi-workshop-function/bootstrap.zip` y la función tenga otro nombre; confundirlos es la causa más común de "function not found".

### Dependencias

| Crate | Versión | Para qué |
|---|---|---|
| `lambda_runtime` | 1, feature `concurrency-tokio` | **Obligatoria** en LMI: habilita `run_concurrent` |
| `polars` | 0.55 con `lazy`, `csv`, `parquet`, `strings`, `performant`, `regex`, `timezones`, `temporal` | Procesamiento columnar con evaluación lazy y paralelismo automático |
| `base64` | 0.22 | Decodificar el CSV que llega en el payload |
| `rand` | 0.8 | Generar datos sintéticos de vuelos |
| `serde` + `serde_json` | 1 | Serializar `Request` y `Response` |
| `tracing` + `tracing-subscriber` | 0.1 / 0.3 con `json` | Logging estructurado |
| `tokio` | 1, feature `full` | Runtime async |

El perfil de release está ajustado para tamaño y velocidad: `opt-level = 3`, `lto = "thin"`, `codegen-units = 1`, `strip = true` y `panic = "abort"`.

> `panic = "abort"` significa que un panic tumba el proceso completo, y con multi-concurrencia se lleva también las demás invocaciones en vuelo en esa instancia. En el handler, devuelve `Err` en vez de hacer panic.

### Estructura de `src/main.rs`

| Símbolo | Qué hace |
|---|---|
| `Request` | Deserializa el payload: `csv_base64` y `generate_rows`, ambos opcionales |
| `Response`, `ProcessingInfo` | Forma del JSON de salida |
| `parse_csv()` | Parsea el CSV desde memoria con un `Cursor`, tratando `NA` como null e infiriendo el esquema con 50.000 filas |
| `generate_flight_csv()` | Genera N filas sintéticas con 10 aerolíneas y 20 aeropuertos reales, y un 2% de cancelaciones |
| `compute_basic_stats()` | Total de vuelos, cancelaciones, tasa de cancelación, delay promedio |
| `compute_flight_analysis()` | Top 5 carriers, top 5 rutas, delay por mes, top 10 aeropuertos |
| `compute_advanced_operations()` | Filtrado complejo, agregaciones por carrier, análisis por hora y columnas derivadas |
| `handler()` | Orquesta carga → tres etapas → `Response`, midiendo tiempos por fase |
| `main()` | Inicializa el logging JSON y arranca `run_concurrent(service_fn(handler))` |

Dos cosas que conviene entender antes de desplegar:

**`run_concurrent` es la única diferencia estructural** frente a una función Lambda normal en Rust, que usaría `lambda_runtime::run`. Es lo que permite que una misma instancia atienda varias invocaciones a la vez, y exige que el closure del handler sea `Clone + Send`. Si no lo es, el código no compila — no es un error que descubras en producción.

**Las tres etapas de análisis son independientes.** Cada una recibe `&DataFrame` y devuelve un `serde_json::Value` que se convierte en un campo de `Response`. Añadir una cuarta etapa es una función más y un campo más, sin tocar las existentes.

### Input de la función

| Campo | Tipo | Descripción |
|---|---|---|
| `csv_base64` | `Option<String>` | CSV codificado en Base64 (hasta ~4 MB de CSV → ~5.3 MB encoded, bajo el límite de 6 MB sync) |
| `generate_rows` | `Option<usize>` | Si no hay CSV, genera N filas de datos sintéticos de vuelos (default: 10,000) |

### Pipeline de procesamiento

| Fase | Función | Qué hace |
|---|---|---|
| **Carga** | `parse_csv()` | Parsea el CSV con Polars directamente desde memoria, sin tocar el disco |
| **Stats** | `compute_basic_stats()` | Total vuelos, cancelaciones, delay promedio |
| **Análisis** | `compute_flight_analysis()` | Top 5 carriers, top 5 rutas, delay por mes, top 10 aeropuertos |
| **Avanzado** | `compute_advanced_operations()` | Filtrado (delay >15min + distancia >500mi), agregaciones por carrier, análisis por hora, columnas derivadas (DelayCategory, DistanceKm, AvgSpeedMph) |

### Diferencias clave vs la versión Python

| Aspecto | Python | Rust |
|---|---|---|
| **Runtime** | `python3.14` | `provided.al2023` (custom runtime) |
| **Concurrencia** | 16 procesos separados por vCPU | 8 async tasks de Tokio por vCPU |
| **Entry point** | `lambda_handler(event, context)` | `run_concurrent(service_fn(handler))` |
| **Feature flag** | No necesario | `concurrency-tokio` en `Cargo.toml` |
| **Packaging** | Zip con `.py` | Zip con binario `bootstrap` compilado |
| **Thread safety** | Automática (procesos separados) | Manual: handler debe ser `Clone + Send`, usar `Arc` para estado compartido |
| **Procesamiento** | Cálculo de primos (simple) | Análisis de vuelos con Polars (CSV, aggregaciones, transformaciones) |
| **Data input** | Inline en payload | Base64 inline o generación sintética |

---

## Módulo 4: Compilar y Desplegar

### Opción recomendada: `deploy-rust-function.sh`

Un solo script cubre los Módulos 4 y 5 completos: compila para arm64, crea la función (o actualiza el código si ya existe), espera a que el update termine, publica una versión, espera a que esté `Active`, la invoca como prueba, muestra las instancias EC2 y guarda `LMI_VERSION` en `workshop/.env`.

```bash
bash workshop/deploy-rust-function.sh
```

Requiere `CP_ARN` y `EXECUTION_ROLE_ARN` en `workshop/.env`; aborta con un mensaje claro si falta alguno. Detecta la arquitectura de la máquina donde lo corres y añade `--arm64` solo si hace falta.

Los pasos manuales que siguen son el equivalente, útiles para entender qué hace cada llamada.

### Paso 4.1: Compilar con cargo-lambda

```bash
cd ./rust-function
cargo lambda build --release --output-format zip --arm64
```

Esto genera el archivo: `target/lambda/lmi-workshop-function/bootstrap.zip`

> **Nota**: Usamos `--arm64` porque el capacity provider está configurado con Graviton (`arm64`). Si necesitaras x86, omite el flag.

### Optimización de microarquitectura para Graviton

Compilar para `arm64` y compilar **optimizado para Graviton** no es lo mismo. Por defecto rustc usa el baseline `armv8-a`, donde la única feature activa es `neon`:

```bash
# Lo que se compila sin configuración extra
rustc --print cfg --target aarch64-unknown-linux-gnu | grep target_feature
#   target_feature="neon"

# Lo que soporta Graviton2 en adelante
rustc --print cfg --target aarch64-unknown-linux-gnu -C target-cpu=neoverse-n1 | grep target_feature
#   aes crc dotprod dpb fp16 lor lse neon pan pmuv3 ras rcpc rdm sha2 spe ssbs vh
```

La que más importa aquí es **`lse`** (Large System Extensions): sin ella cada operación atómica se compila como un bucle load-linked/store-conditional en lugar de una sola instrucción. Con `run_concurrent` y 8 tasks de Tokio por vCPU compartiendo los refcounts internos de Polars, ese es un camino caliente.

El repositorio lo activa en [`rust-function/.cargo/config.toml`](rust-function/.cargo/config.toml):

```toml
[target.aarch64-unknown-linux-gnu]
rustflags = ["-C", "target-cpu=neoverse-n1"]
```

`neoverse-n1` es Graviton2 (armv8.2-a), el mínimo común denominador seguro: cualquier instancia Graviton2, 3 o 4 que Lambda elija ejecuta el binario.

> **No subir a `neoverse-v2`** (Graviton4) sin restringir antes `InstanceRequirements` en el capacity provider a esa generación. El provider del workshop solo pide `Architectures=[arm64]` y Lambda mezcla familias según disponibilidad; si el binario usa instrucciones que la instancia asignada no tiene, el proceso muere con SIGILL de forma intermitente y solo bajo scaling — un fallo muy desagradable de diagnosticar. Tampoco usar `target-cpu=native`, que compila contra el CPU de la máquina de build.

Cambiar estos flags invalida el caché de compilación: la siguiente build recompila las ~292 crates del árbol, incluido Polars.

### Paso 4.2: Obtener el ARN del Capacity Provider

```bash
export CP_ARN=$(aws lambda get-capacity-provider \
  --capacity-provider-name lmi-workshop-capacity-provider \
  --query "CapacityProvider.CapacityProviderArn" \
  --output text)

echo "Capacity Provider ARN: $CP_ARN"
echo "Execution Role: $EXECUTION_ROLE_ARN"
```

Ambos valores deben estar poblados.

### Paso 4.3: Crear la función Lambda

```bash
aws lambda create-function \
  --function-name lmi-workshop-rust-function \
  --runtime provided.al2023 \
  --handler rust.handler \
  --architectures arm64 \
  --zip-file fileb://target/lambda/lmi-workshop-function/bootstrap.zip \
  --role "$EXECUTION_ROLE_ARN" \
  --memory-size 2048 \
  --capacity-provider-config "LambdaManagedInstancesCapacityProviderConfig={CapacityProviderArn=$CP_ARN,ExecutionEnvironmentMemoryGiBPerVCpu=2.0}"
```

Deberías ver un output similar a:

```json
{
    "FunctionName": "lmi-workshop-rust-function",
    "FunctionArn": "arn:aws:lambda:us-east-1:123456789012:function:lmi-workshop-rust-function",
    "Runtime": "provided.al2023",
    "Role": "arn:aws:iam::123456789012:role/LMIWorkshopExecutionRole",
    "Handler": "rust.handler",
    "CodeSize": 3421,
    "Timeout": 3,
    "MemorySize": 2048,
    "State": "Pending",
    "Architectures": ["arm64"],
    "CapacityProviderConfig": {
        "LambdaManagedInstancesCapacityProviderConfig": {
            "CapacityProviderArn": "arn:aws:lambda:us-east-1:123456789012:capacity-provider:lmi-workshop-capacity-provider",
            "PerExecutionEnvironmentMaxConcurrency": 8,
            "ExecutionEnvironmentMemoryGiBPerVCpu": 2.0
        }
    }
}
```

> **Nota**: `PerExecutionEnvironmentMaxConcurrency` es **8** para Rust (vs 16 para Python). Rust usa async tasks de Tokio, y cada worker maneja exactamente un request en vuelo sin multiplexing.

### Parámetros clave de configuración

| Parámetro | Valor | Descripción |
|---|---|---|
| `--runtime provided.al2023` | OS-only runtime | Rust compila a binario nativo, no necesita runtime gestionado |
| `--handler rust.handler` | Convención | Para custom runtimes el handler es ignorado (el binario `bootstrap` es el entry point) |
| `--memory-size 2048` | 2048 MB | Determina el tamaño del ambiente de ejecución. Con ratio 2:1 = 1 vCPU |
| `ExecutionEnvironmentMemoryGiBPerVCpu=2.0` | Ratio 2:1 | Lambda selecciona instancias compute-optimized |
| `PerExecutionEnvironmentMaxConcurrency=8` | 8 por vCPU (default Rust) | 1 vCPU = 8 requests concurrentes; 2 vCPU = 16 |

### Paso 4.4: Verificar que la función fue creada

```bash
aws lambda get-function \
  --function-name lmi-workshop-rust-function \
  --query "Configuration.[FunctionName,State]" \
  --output text
```

Resultado esperado: `lmi-workshop-rust-function   ActiveNonInvocable`

El estado `ActiveNonInvocable` significa que la función existe pero no puede ser invocada aún — necesita una versión publicada.

---

## Módulo 5: Publicar Versión e Invocar

> Si ejecutaste `deploy-rust-function.sh` en el módulo anterior, los pasos 5.1 a 5.4 ya están hechos: la versión está publicada, `Active` e invocada, y `LMI_VERSION` está en `workshop/.env`. Pasa al Paso 5.5 o usa `invoke.sh` para seguir invocando.

### Opción recomendada para invocar: `invoke.sh`

Resuelve la versión desde `workshop/.env`, construye el payload, codifica el CSV en Base64 si le pasas un archivo, y **detecta fallos de función**: aunque Lambda devuelva `StatusCode: 200`, el script sale con `exit 1` si la respuesta trae `FunctionError` (por ejemplo `Runtime.OutOfMemory`).

```bash
# Generar 50.000 filas sintéticas
bash workshop/invoke.sh -g 50000

# Enviar tu propio CSV (lo codifica en Base64 por ti)
bash workshop/invoke.sh -f tu_archivo.csv

# Apuntar a otra versión u otra función
bash workshop/invoke.sh -g 50000 -v 3
bash workshop/invoke.sh -g 50000 -n mi-otra-funcion
```

| Opción | Descripción |
|---|---|
| `-g`, `--generate N` | Filas sintéticas a generar |
| `-f`, `--file CSV` | CSV local a enviar en Base64 |
| `-n`, `--name NOMBRE` | Función a invocar (default: `lmi-workshop-rust-function`) |
| `-v`, `--version VER` | Versión publicada (default: `$LMI_VERSION` del `.env`) |
| `-o`, `--output ARCHIVO` | Dónde guardar la respuesta |

Los pasos manuales que siguen explican qué hace por dentro.

### Paso 5.1: Publicar una versión

Publicar una versión es lo que **desencadena el aprovisionamiento de instancias EC2**.

```bash
export LMI_VERSION=$(aws lambda publish-version \
  --function-name lmi-workshop-rust-function \
  --description "Initial Rust LMI deployment" \
  --query "Version" \
  --output text)

echo "Published version: $LMI_VERSION"
```

### Paso 5.2: Esperar a que la función esté activa

El aprovisionamiento toma de 2 a 5 minutos:

```bash
echo "Esperando a que lmi-workshop-rust-function:$LMI_VERSION esté Active..."
while [ "$(aws lambda get-function \
  --function-name lmi-workshop-rust-function:$LMI_VERSION \
  --query 'Configuration.State' \
  --output text)" != "Active" ]; do
  echo "  Aún aprovisionando... ($(date +%H:%M:%S))"
  sleep 15
done
echo "¡Función activa!"
```

### Paso 5.3: Verificar el estado

```bash
aws lambda get-function \
  --function-name lmi-workshop-rust-function:$LMI_VERSION \
  --query "Configuration.State" \
  --output text
```

Resultado esperado: `Active`

### Paso 5.4: Invocar la función (datos generados)

La forma más rápida de probar es generar datos sintéticos de vuelos directamente en la función:

```bash
aws lambda invoke \
  --function-name lmi-workshop-rust-function:$LMI_VERSION \
  --payload '{"generate_rows": 50000}' \
  --cli-binary-format raw-in-base64-out \
  response.json

cat response.json | python3 -m json.tool
```

Resultado esperado:

```json
{
    "status_code": 200,
    "request_id": "abc123-def456",
    "processing": {
        "source": "generated_50000_rows",
        "rows": 50000,
        "columns": 15,
        "memory_mb": 3.82,
        "load_duration_seconds": 0.045
    },
    "stats": {
        "total_flights": 50000,
        "cancelled_flights": 1012,
        "cancellation_rate_pct": 2.02,
        "avg_delay_minutes": 75.31
    },
    "analysis": {
        "top_carriers": [
            {"carrier": "WN", "flights": 5102},
            {"carrier": "AA", "flights": 5048}
        ],
        "top_routes": [
            {"route": "ATL-ORD", "flights": 142}
        ],
        "delay_by_month": [
            {"month": 1, "avg_delay": 74.8},
            {"month": 2, "avg_delay": 76.1}
        ],
        "top_airports": [
            {"airport": "ATL", "flights": 2531}
        ]
    },
    "advanced": {
        "filtered_delayed_long_distance": 12483,
        "carrier_performance": [...],
        "delay_by_departure_hour": [...],
        "delay_categories": [
            {"category": "VeryDelayed", "count": 12105},
            {"category": "Delayed", "count": 10982}
        ],
        "derived_columns_added": 3
    },
    "total_duration_seconds": 0.123
}
```

> **Observa**: La función ejecuta un pipeline completo de análisis de datos (carga CSV, estadísticas, aggregaciones con Polars, columnas derivadas) sin cold start. Los datos sintéticos incluyen 10 aerolíneas reales y 20 aeropuertos.

### Paso 5.4b: Invocar con CSV propio (Base64)

Para enviar tu propio CSV, codifícalo en Base64:

```bash
# Codificar un CSV pequeño (máximo ~4 MB para invocación síncrona)
CSV_B64=$(base64 -w 0 < tu_archivo.csv)

aws lambda invoke \
  --function-name lmi-workshop-rust-function:$LMI_VERSION \
  --payload "{\"csv_base64\": \"$CSV_B64\"}" \
  --cli-binary-format raw-in-base64-out \
  response.json

cat response.json | python3 -m json.tool
```

> **Límites de payload**: Invocación síncrona: 6 MB (≈ 4 MB de CSV). Invocación asíncrona: 256 KB. Para archivos más grandes, considera integrar S3 como fuente de datos.

### Paso 5.5: Verificar las instancias EC2 gestionadas

```bash
aws ec2 describe-instances \
  --include-managed-resources \
  --filters "Name=tag:aws:lambda:capacity-provider,Values=*lmi-workshop-capacity-provider" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,Placement.AvailabilityZone]" \
  --output table
```

Deberías ver 3 instancias corriendo distribuidas en diferentes AZs:

```
-------------------------------------------------------------------
|                        DescribeInstances                        |
+----------------------+-------------+----------+-----------------+
|  i-0abc123def456789  |  m7g.xlarge |  running |  us-east-1a     |
|  i-0def456ghi789012  |  m7g.xlarge |  running |  us-east-1b     |
|  i-0ghi789jkl012345  |  m7g.xlarge |  running |  us-east-1c     |
+----------------------+-------------+----------+-----------------+
```

### ¿Qué pasó?

Al publicar la versión, Lambda:

1. Lanzó **3 instancias EC2** (mínimo para resiliencia entre AZs) en tus subredes privadas
2. Inició **3 ambientes de ejecución** con el binario Rust compilado
3. Marcó la versión como **Active** cuando los ambientes estaban listos

---

## Módulo 6: Patrones Avanzados de Concurrencia en Rust

Con `run_concurrent`, varias invocaciones corren **en el mismo proceso** y comparten memoria. Eso cambia las reglas frente a Lambda estándar, donde cada invocación tenía su propio entorno aislado. La función del workshop es deliberadamente sin estado —cada invocación construye su propio `DataFrame` y no toca nada compartido—, así que sirve como referencia de lo que hace el runtime, pero no de estos patrones. Para verlos aplicados, la [documentación de `lambda_runtime`](https://docs.rs/lambda_runtime/) tiene ejemplos completos y compilables.

### Estado compartido

Lo que necesites compartir entre invocaciones (clientes, configuración, pools de conexión) se construye **una vez en `main()`**, antes de `run_concurrent`, y se inyecta en el closure del handler:

| Qué compartes | Cómo | Por qué |
|---|---|---|
| Cliente del AWS SDK | `.clone()` directo, sin envolver | Los clientes del SDK para Rust ya son concurrency-safe y su clone es económico (comparten el pool HTTP internamente) |
| Configuración inmutable, structs propios | `Arc<T>` clonado en cada invocación | Evita copiar el dato por invocación |
| Estado **mutable** | `Arc<Mutex<T>>` o `Arc<RwLock<T>>` | Sin esto hay data race, y el compilador lo rechaza |

El patrón es siempre el mismo: mover el estado al closure con `move`, clonarlo al principio de cada invocación y pasar la copia al handler. Si el closure no acaba siendo `Clone + Send`, **el código no compila** — es un error de compilación, no algo que descubras en producción bajo carga.

### Consideraciones de thread safety

| Aspecto | Guía |
|---|---|
| **Estado mutable compartido** | Usar `Arc<Mutex<T>>` o `Arc<RwLock<T>>` |
| **Clientes AWS SDK** | Son `Clone + Send` — usar `.clone()` directamente, sin `Arc` |
| **Directorio `/tmp`** | Compartido entre invocaciones concurrentes: usar nombres únicos por request (incluir `request_id`). La función del workshop lo evita parseando el CSV desde memoria |
| **Handler closure** | Debe implementar `Clone + Send` — si no, el código no compila |
| **Variables de entorno** | Inmutables, seguras para leer concurrentemente |
| **`panic!`** | Con `panic = "abort"` en el perfil de release, un panic tumba el proceso y con él las demás invocaciones en vuelo. Devolver `Err` siempre |

### Logging estructurado

En multi-concurrencia los logs de distintas invocaciones se entrelazan, así que una línea de texto plano no basta para reconstruir qué pasó en un request. La función inicializa `tracing_subscriber` en modo JSON y emite eventos con campos (`rows`, `columns`, `source`) en lugar de cadenas interpoladas, de modo que CloudWatch Logs Insights pueda filtrarlos por campo. Para correlacionar todos los eventos de una invocación, incluye el `request_id` (disponible en `event.context.request_id`) como campo del span.

Ver `main()` y `handler()` en [`rust-function/src/main.rs`](rust-function/src/main.rs).

### X-Ray Trace ID

En LMI el trace ID **no** se propaga por la variable de entorno `_X_AMZN_TRACE_ID`, a diferencia de Lambda estándar. Está en el contexto de la invocación, en el campo `xray_trace_id` de `event.context`. Cualquier código que dependa de leer esa variable de entorno deja de funcionar al migrar a LMI.

---

## Módulo 7: Timeout de 90 minutos (Opcional)

LMI soporta un timeout máximo de **90 minutos (5,400 segundos)** para invocaciones **asíncronas** y **event source mappings**, comparado con los 15 minutos de Lambda estándar.

### Configurar el timeout extendido

```bash
aws lambda update-function-configuration \
  --function-name lmi-workshop-rust-function \
  --timeout 5400
```

### Limitaciones

- Solo aplica a invocaciones **asíncronas** y **event source mappings**
- Invocaciones **síncronas** mantienen el máximo de 15 minutos
- La fase de inicialización (Init) sigue limitada a 15 minutos
- Planifica para conexiones y credenciales que pueden expirar durante la ejecución

### Invocar de forma asíncrona

```bash
aws lambda invoke \
  --function-name lmi-workshop-rust-function:$LMI_VERSION \
  --invocation-type Event \
  --payload '{"generate_rows": 20000000}' \
  --cli-binary-format raw-in-base64-out \
  response.json
```

> La invocación asíncrona devuelve `202` de inmediato y **no** trae el resultado: `response.json` queda vacío. Para ver la salida hay que mirar los logs de CloudWatch. `invoke.sh` solo hace invocaciones síncronas, así que este paso va a mano.

---

## Módulo 8: Graceful Shutdown

Cuando el capacity provider escala hacia abajo o recicla una instancia, Lambda envía **SIGTERM** al proceso antes de terminarlo. En LMI eso importa más que en Lambda estándar: la instancia puede tener hasta 8 invocaciones en vuelo, y todas mueren con el proceso.

`lambda_runtime` expone `spawn_graceful_shutdown_handler()`, que se llama en `main()` antes de `run_concurrent` y da una ventana para hacer flush de buffers de logs o métricas, cerrar conexiones y terminar el trabajo en curso.

La función de este workshop **no lo usa**: es sin estado, no acumula nada en buffers y cada invocación es idempotente, así que no hay nada que preservar. Si tu función escribe en lotes, mantiene conexiones abiertas o agrega métricas en memoria, añádelo. Detalles y firma exacta en la [documentación de `lambda_runtime`](https://docs.rs/lambda_runtime/).

---

## Módulo 9: Limpieza (Cleanup)

Las instancias EC2 corren 24/7 mientras exista el capacity provider, haya o no invocaciones. Este módulo no es opcional.

### Opción recomendada: `cleanup.sh`

Borra las versiones publicadas una a una, después la función, luego el capacity provider, espera a que las instancias terminen, verifica que no quede nada y elimina `workshop/.env`:

```bash
bash workshop/cleanup.sh
```

Si ejecutaste el módulo de multi-tenancy (ver [`WORKSHOP-MULTI-TENANCY.md`](WORKSHOP-MULTI-TENANCY.md)), corre además `bash workshop/cleanup-multi-tenancy.sh`, que borra el provider de Tenant B y el encriptado sin tocar el principal.

Los pasos manuales que siguen son el equivalente, en el orden correcto.

### Paso 9.1: Eliminar la función Lambda

```bash
aws lambda delete-function \
  --function-name lmi-workshop-rust-function
```

### Paso 9.2: Eliminar el Capacity Provider

```bash
aws lambda delete-capacity-provider \
  --capacity-provider-name lmi-workshop-capacity-provider
```

Lambda terminará automáticamente todas las instancias EC2 gestionadas.

### Paso 9.3: Verificar que las instancias fueron terminadas

```bash
aws ec2 describe-instances \
  --include-managed-resources \
  --filters "Name=tag:aws:lambda:capacity-provider,Values=*lmi-workshop-capacity-provider" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,State.Name]" \
  --output table
```

No deberías ver instancias en estado `running`.

---

## Módulo 10: Prueba de Carga Paralela

### Script de carga paralela (`invoke-parallel.sh`)

Lanza múltiples invocaciones concurrentes en background para saturar el capacity provider y observar el auto-scaling. Igual que `invoke.sh` (Módulo 5), inspecciona `FunctionError` en cada respuesta, así que distingue una invocación que falló dentro de la función (`ERROR`, con su `errorType`) de una que la CLI ni pudo entregar (`FAIL`, típicamente `TooManyRequestsException`):

```bash
# 5 invocaciones x 2M filas = 10M filas (default)
bash workshop/invoke-parallel.sh

# 8 invocaciones x 5M filas = 40M filas
bash workshop/invoke-parallel.sh -c 8 -r 5000000

# 28 invocaciones x 5M filas = 140M filas
bash workshop/invoke-parallel.sh -c 28 -r 5000000
```

| Opción | Descripción |
|---|---|
| `-c, --concurrency N` | Invocaciones en paralelo (default: 5) |
| `-r, --rows ROWS` | Filas por invocación (default: 2,000,000) |
| `-v, --version VER` | Versión publicada (default: `$LMI_VERSION`) |

El script muestra tiempo total, tiempo de función, throughput (filas/seg) y detalle de errores.

### Hallazgo: Comportamiento de scaling y warm instances

Con `ScalingMode: Auto` y `MaxVCpuCount: 30`, se realizaron pruebas progresivas:

| Test | Concurrencia | Filas totales | Tiempo | Throughput | Fallidas |
|---|---|---|---|---|---|
| 1 - Baseline | 28 | 140M | 32.8s | 4.2M filas/seg | 0 |
| 2 - Cold burst | 128 | 640M | 77.6s | 8.2M filas/seg | 30 (throttled) |
| 3 - Warm re-run | 128 | 640M | 61.3s | **10.4M filas/seg** | 0 |

**Observaciones clave:**

1. **Throttling por velocidad de scaling, no por límite de vCPUs** — el test 2 y 3 usaron el mismo `MaxVCpuCount: 30`. En el test 2, 30 invocaciones fueron throttleadas (122 throttles en CloudWatch) porque Lambda no podía aprovisionar instancias tan rápido como llegaban las requests. En el test 3, las instancias ya estaban calientes del test anterior y las 128 invocaciones se ejecutaron sin problemas.

2. **CPU Utilization se mantiene en ~70%** — en modo `Auto`, Lambda mantiene capacidad ociosa intencionalmente para absorber picos sin throttling. No es un problema, es diseño.

3. **Lambda escala en oleadas** — las invocaciones no se ejecutan simultáneamente en cold burst. Se distribuyen en oleadas espaciadas 4-8 segundos mientras Lambda aprovisiona nuevas instancias.

4. **Función internamente consistente (~3.2-3.9s)** — el tiempo de procesamiento por invocación es estable independientemente de la concurrencia; la variación en tiempo total es por scheduling de instancias.

5. **Warm instances eliminan throttling** — una vez que las instancias están escaladas, la misma carga que antes throttleó se ejecuta completa y más rápido (61s vs 77s).

### Opciones para mayor utilización

| Opción | Cómo | Efecto |
|---|---|---|
| **Pre-calentar con carga gradual** | Ejecutar un test con baja concurrencia antes del burst | Las instancias escalan progresivamente y están listas para el pico |
| **Modo Manual con target alto** | Cambiar `ScalingMode` a `Manual` con `TargetTrackingScalingPolicy.cpu_utilization(85)` | Lambda escala solo cuando CPU supera 85% |
| **Scheduled scaling** | Usar EventBridge Scheduler para subir capacidad antes de picos predecibles | Instancias listas sin carga previa |
| **Modo Auto (default)** | No cambiar nada | Lambda optimiza por latencia, ~70% CPU es esperado |

### Tipos de fallo bajo carga

Las pruebas de carga revelaron tres tipos distintos de fallo, cada uno con causa y momento diferente:

| Error | Causa | Cuándo ocurre |
|---|---|---|
| `TooManyRequestsException` (throttling) | Instancias aún no aprovisionadas | Cold burst — primera oleada de carga cuando no hay instancias warm |
| `Runtime.OutOfMemory` | Memoria insuficiente por multi-concurrencia | Muchas invocaciones pesadas (~499 MB cada una) colocadas en la misma instancia. Con 8 invocaciones × 499 MB ≈ 4 GB, excede el ratio 2:1 |
| `TooManyRequestsException` (high CPU utilization) | CPU saturada, no hay slots libres | Instancias warm pero todas con 8 invocaciones al máximo. Lambda rechaza en vez de degradar latencia para las demás |

> **Nota**: Los errores de throttling y high CPU no aparecen en los logs de la función porque Lambda los rechaza **antes de ejecutar**. Solo son visibles en la métrica `Throttles` de CloudWatch o en la respuesta de la CLI.

---

## Troubleshooting

| Problema | Causa | Solución |
|---|---|---|
| Estado se queda en "Pending" >5 min | Demora en aprovisionamiento | Verificar que el capacity provider esté "Active". Esperar. El primer publish puede tomar hasta 5 min |
| "InvalidParameterValueException" | ARN del capacity provider incorrecto | Verificar `echo $CP_ARN` |
| Función creada pero no se puede invocar | Invocando `$LATEST` en vez de la versión | Siempre invocar con calificador de versión: `:$LMI_VERSION` |
| `TooManyRequestsException` (throttling) | Instancias aún no escalaron para la carga | Lambda throttlea mientras aprovisiona. Re-intentar — las warm instances absorben la carga. Para picos predecibles, pre-calentar con carga gradual o usar scheduled scaling |
| `TooManyRequestsException` (high CPU) | CPU saturada, todos los slots ocupados | Todas las instancias tienen sus 8 invocaciones concurrentes al máximo. Lambda rechaza en vez de degradar latencia. Reducir concurrencia, bajar `PerExecutionEnvironmentMaxConcurrency`, o subir `MaxVCpuCount` |
| Error de compilación: handler not Clone + Send | Estado mutable sin `Arc` | Envolver estado compartido en `Arc<T>` y clonar el `Arc` en cada invocación |
| `zsh: no matches found` | Brackets sin comillas | Envolver valores de `--vpc-config` e `--instance-requirements` en comillas dobles |
| `lambda_runtime` version error | Versión < 1.1.1 | Actualizar a `lambda_runtime >= 1.1.1` con feature `concurrency-tokio` |
| `StatusCode: 200` pero `FunctionError: "Unhandled"` | StatusCode refleja la API, no la función | Inspeccionar `FunctionError` en la respuesta; usar `invoke.sh` que lo detecta automáticamente |
| `Runtime.OutOfMemory` | Memoria insuficiente por multi-concurrencia | Con 8 invocaciones de ~499 MB cada una en la misma instancia se necesitan ~4 GB. Opciones: subir `ExecutionEnvironmentMemoryGiBPerVCpu` a 4.0, reducir filas por invocación, o bajar `PerExecutionEnvironmentMaxConcurrency` |
| CPU Utilization estancada en ~70% | Modo `Auto` mantiene margen para absorber picos | Cambiar a `ScalingMode: Manual` con target CPU alto si se necesita mayor utilización |

---

## Resumen de Versiones Requeridas

| Dependencia | Versión mínima | Nota |
|---|---|---|
| `lambda_runtime` | 1.1.1 | Con feature `concurrency-tokio` habilitada |
| Rust (MSRV) | 1.84.0 | Minimum Supported Rust Version para LMI |
| AWS CLI | v2 | Requerido para `--include-managed-resources` |

---

## Referencias

- [Lambda Managed Instances overview](https://docs.aws.amazon.com/lambda/latest/dg/lambda-managed-instances.html)
- [Rust support for Lambda Managed Instances](https://docs.aws.amazon.com/lambda/latest/dg/lambda-managed-instances-rust.html)
- [Lambda Managed Instances runtimes](https://docs.aws.amazon.com/lambda/latest/dg/lambda-managed-instances-runtimes.html)
- [Building Lambda functions with Rust](https://docs.aws.amazon.com/lambda/latest/dg/rust-handler.html)
- [Deploy Rust Lambda functions with .zip file archives](https://docs.aws.amazon.com/lambda/latest/dg/rust-package.html)
- [Getting started with Lambda Managed Instances](https://docs.aws.amazon.com/lambda/latest/dg/lambda-managed-instances-getting-started.html)
- [Build high-performance apps with Lambda Managed Instances (blog)](https://aws.amazon.com/blogs/compute/build-high-performance-apps-with-aws-lambda-managed-instances/)
- [Building serverless applications with Rust on AWS Lambda (blog)](https://aws.amazon.com/blogs/compute/building-serverless-applications-with-rust-on-aws-lambda/)
