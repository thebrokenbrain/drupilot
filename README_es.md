<p align="center">
  <img src="docs/assets/drupilot.png" alt="drupilot — Code. Fly. Conquer. Un plugin de Claude Code para portar de Drupal 9/10 a Drupal 11" width="100%">
</p>

# drupilot

> Un plugin de Claude Code que porta módulos y temas de Drupal 9/10 a **Drupal 11**: evalúa la viabilidad, aplica la portabilidad (compatibilidad mínima y/o un refactor completo al "estilo Drupal 11"), adapta y ejecuta la suite de tests **completa** dentro de DDEV, y te ayuda a **contribuir el resultado a Drupal.org** (issue fork + Merge Request, o un parche legacy).

*Léelo en inglés: [README.md](README.md).*

`drupilot` = **Drupal** + **co-pilot** (copiloto). Es tu copiloto en el viaje D9/10 → D11: nunca se niega ante un módulo difícil — si un refactor completo es desproporcionado, aun así te entrega un plan por etapas que respeta la funcionalidad original y te deja a ti la decisión final.

> **Nota sobre el idioma:** todo el contenido funcional del plugin (mensajes, informes, prompts) está **en inglés** a propósito. Este `README_es.md` es la traducción al español de la documentación; el resto del plugin no contiene español.

---

## Índice

- [Qué hace](#qué-hace)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Inicio rápido](#inicio-rápido)
- [Comandos](#comandos)
- [Filosofía de portabilidad en dos fases](#filosofía-de-portabilidad-en-dos-fases)
  - [Anotaciones de plugins a atributos PHP 8](#anotaciones-de-plugins-a-atributos-php-8)
  - [Verificar la mitad Drupal 10](#verificar-la-mitad-drupal-10)
- [Qué es automático vs. dónde decide la IA](#qué-es-automático-vs-dónde-decide-la-ia)
- [Modo autónomo (manos fuera)](#modo-autónomo-manos-fuera)
- [Ejecutar bajo otra herramienta (contrato no interactivo)](#ejecutar-bajo-otra-herramienta-contrato-no-interactivo)
- [Espacios de trabajo, salidas y estado](#espacios-de-trabajo-salidas-y-estado)
  - [Apuntando a un checkout suelto](#apuntando-a-un-checkout-suelto)
  - [La carpeta `.drupilot/`](#la-carpeta-drupilot)
  - [Registro de decisiones](#registro-de-decisiones)
  - [Patrones aprendidos](#patrones-aprendidos)
  - [Estado por módulo](#estado-por-módulo)
  - [Limpiar bancos de pruebas](#limpiar-bancos-de-pruebas)
  - [Core base cacheado](#core-base-cacheado)
- [Configuración](#configuración)
  - [Pre-responder elecciones en pestañas](#pre-responder-elecciones-en-pestañas)
- [Determinismo (reproducible por defecto)](#determinismo-reproducible-por-defecto)
- [Casos de uso](#casos-de-uso)
  - [1. "¿Merece la pena portar este módulo?" — solo evaluación](#1-merece-la-pena-portar-este-módulo--solo-evaluación)
  - [2. Portabilidad guiada de principio a fin de un módulo custom](#2-portabilidad-guiada-de-principio-a-fin-de-un-módulo-custom)
  - [3. Solo portabilidad mínima (Fase 1), sin refactor](#3-solo-portabilidad-mínima-fase-1-sin-refactor)
  - [4. Modernizar al "estilo Drupal 11" (Fase 2)](#4-modernizar-al-estilo-drupal-11-fase-2)
  - [5. Ejecutar la suite de tests completa en DDEV](#5-ejecutar-la-suite-de-tests-completa-en-ddev)
  - [6. Obtén el parche — prueba en local ahora, contribuye después](#6-obtén-el-parche--prueba-en-local-ahora-contribuye-después)
  - [7. Portar por capas los módulos custom de un monorepo](#7-portar-por-capas-los-módulos-custom-de-un-monorepo)
  - [8. Contribuir el arreglo de vuelta a Drupal.org](#8-contribuir-el-arreglo-de-vuelta-a-drupalorg)
- [Cómo funciona (arquitectura)](#cómo-funciona-arquitectura)
  - [Referencia de scripts](#referencia-de-scripts)
- [La capa complementaria drupal-digests](#la-capa-complementaria-drupal-digests)
- [Seguridad y convenciones](#seguridad-y-convenciones)
- [Resolución de problemas](#resolución-de-problemas)
- [Desarrollo de drupilot](#desarrollo-de-drupilot)
- [Licencia](#licencia)

---

## Qué hace

- **Estudio de viabilidad** — un análisis estático no destructivo (Rector en dry-run, PHPStan, PHPCS, y opcionalmente Upgrade Status) que estima qué parte del trabajo es autocorregible vs. manual, clasifica las rupturas duras (Twig 3, CKEditor 5, jQuery UI, Symfony 7), revisa el `info.yml` y el soporte D11 de las dependencias contrib, recomienda un **target de compatibilidad de core** (`^11` vs `^10 || ^11`, el `require.php` que implica y un veredicto SemVer de subida de versión), y produce un informe markdown más un **plan de portabilidad por etapas** con un veredicto de esfuerzo S/M/L/XL.
- **Portabilidad mínima (Fase 1)** — el conjunto de cambios más pequeño para que el módulo/tema funcione en Drupal 11 **respetando la funcionalidad original**. Motor: `palantirnet/drupal-rector`, una capa opcional de reglas IA (`dbuytaert/drupal-digests`) y ajustes manuales puntuales.
- **Refactor completo (Fase 2, opt-in)** — una reescritura a las mejores prácticas modernas de Drupal 11: atributos PHP 8 para plugins, inyección de dependencias, tipados estrictos, cero deprecaciones, `Drupal` + `DrupalPractice` limpios y suite de tests en verde.
- **Tests** — descubre, adapta y ejecuta la suite PHPUnit completa (Unit / Kernel / Functional / FunctionalJavascript) dentro de DDEV (con Selenium para JS), iterando hasta verde y reportando cobertura. Los fallos **nunca** se silencian.
- **Contribución** — prepara y (opcionalmente) publica el resultado a Drupal.org mediante el flujo moderno issue-fork + Merge Request, o un parche legacy, en modo **semiautomático** (confirma cada acción externa) o **totalmente automático**. Genera el **resumen del issue y los valores recomendados de los campos obligatorios** (Title, Category, Priority, Version, Component, Assigned) para pegarlos en el formulario web, además de un breve **comentario**. Siempre se genera un `.patch` junto al MR y se **verifica que aplica limpio** sobre la versión a la que se refiere, para que tú (o cualquiera) puedas adjuntarlo y aplicarlo en el issue antes de que el maintainer lo fusione.
- **Parches, desacoplados de la contribución** — obtén el `.patch` de la portabilidad cuando quieras con **`/drupilot-patch`**: offline, sin push, sin cuenta de Drupal.org. Elige un parche local de pruebas (`MODULE-port-to-drupal-11.patch`) **o** uno con el nombre de la convención issue-comment para adjuntarlo a un issue y probarlo ya — y contribuye el Merge Request más tarde, como paso aparte.
- **Muchos módulos, en orden** — **`/drupilot-layers`** toma un conjunto completo (el `web/modules/custom` de un monorepo, una carpeta de módulos), calcula las **capas de portabilidad** a partir de las dependencias declaradas *y* de las que el código usa de verdad (clases, servicios, rutas, librerías, plugins), informa de los ciclos de dependencias y de las **dependencias no declaradas** con la entrada de `dependencies:` que hay que añadir, y porta capa a capa con el flujo normal y un informe consolidado por capa.
- **Higiene previa, informada** — un lint de metadatos señala configuración sin schema, una ruta de `configure:` que no existe, servicios huérfanos, argumentos de servicio que no casan con el constructor, submódulos que se quedaron en un `core_version_requirement` obsoleto y dependencias no declaradas. Aparece en los informes de viabilidad y de port y nunca cambia el veredicto de esfuerzo. La Fase 1 solo arregla el requisito de core de los submódulos, que actualiza junto con el `info.yml` principal.
- **Tú mantienes el control** — las decisiones de peso son **elecciones en pestañas** (target de core, target de PHP, qué reglas digests aplicar, alcance del refactor, hacer push o no), con la recomendación preseleccionada y tus respuestas recordadas por proyecto. Nada importante ocurre en silencio.
- **Información, no solo salida** — un **boletín** por portabilidad (`port-report.md`: qué cambió y por qué, el veredicto de preservación), un **panel de preparación D11 de las dependencias** (qué deps contrib bloquean la portabilidad), una **búsqueda de issue upstream** (¿hay alguien ya portando esto?) y un **explicador de deprecaciones** que convierte la salida críptica en un fix + un enlace a los change-records.

El target de PHP configurado por defecto es **8.3**, el suelo seguro, que se usa siempre que no se muestra la pestaña (una ejecución autónoma, o con `DRUPILOT_PHP_TARGET` ya fijado); la pestaña guiada de `/drupilot-setup` recomienda y preselecciona **8.4**, y ofrece 8.3 como suelo seguro. El target es totalmente configurable; todo (nivel de PHPStan, sniffs de PHPCS, `php_version` de DDEV) deriva de un único ajuste. Los sets de PHP de Rector siguen en cambio el suelo del rango de core declarado y del `require.php` de composer (normalmente 8.1 para `^10 || ^11`), nunca por encima del target, de modo que el pase oficial de Rector no añade sintaxis que el PHP más bajo declarado no pueda ejecutar, hasta donde los datos de versiones de drupilot conocen ese PHP (una pata de Drupal 9 que se mantiene sin `require.php` en composer cae a PHP 7.4, con un aviso). Las elecciones del flujo persisten en un `.drupilot.json` por proyecto (leído entre las variables de entorno y los valores por defecto).

---

## Requisitos

`drupilot` valida solo lo que necesita cada operación, así que no necesitas Docker solo para ejecutar un análisis estático. Ejecuta `/drupilot-doctor` en cualquier momento para una tabla de estado por plataforma e instalación asistida.

| Operación | Requisitos duros | Opcionales / blandos |
| --- | --- | --- |
| **Análisis** (`assess`, `port` estático) | `git`, `jq`, y `composer` o `php` ≥ target | — |
| **Entorno y tests** (`setup`, `test`) | **Docker** (daemon activo) + **DDEV** (una versión con soporte Drupal 11) | add-on Selenium (para FunctionalJavascript), espacio en disco |
| **Contribución** (Drupal.org) | `git`, cuenta drupal.org + acceso a GitLab, y una **clave SSH** o un **PAT** | `glab`/`curl` para la API de GitLab (degradable) |

DDEV provee el entorno Drupal completo (web + base de datos + chromedriver) sobre Docker — **no necesitas montar un stack LAMP tú mismo**.

**Shell:** los scripts y hooks funcionan con **bash ≥ 3.2** y no asumen herramientas GNU, así que un macOS de serie (`/bin/bash` 3.2, `sed`/`grep` BSD) funciona tal cual — no hace falta el bash de Homebrew ni GNU coreutils. `/drupilot-doctor` informa de la versión de bash encontrada.

**Comprobaciones de salud.** Además de los requisitos, `/drupilot-doctor` ejecuta `preflight.sh --extended`, un conjunto de comprobaciones solo informativas de fallos conocidos (nunca bloquean un comando): `xmllint` presente, la variante de `sed` (GNU o BSD), un `phpcs.xml.dist` bien formado y un `phpstan.neon` sin el parámetro obsoleto `drupal_root` en la raíz de Drupal, el toolchain de desarrollo instalado frente a la referencia verificada de `config/toolchain-reference.json` (leído de `composer.lock`, con un aviso si es una combinación que se sabe rota, como la que provoca "Could not detect twig set"), el espacio libre en disco (`requirements.disk_free_min_mb`, 5 GB por defecto) y restos de drupilot o DDEV en el checkout original de tu módulo. Ejecútalo desde el módulo o desde la raíz de Drupal. El JSON (`--extended --json`) añade filas con `category: "health"` y un objeto `toolchain`; las claves existentes no cambian.

---

## Instalación

`drupilot` se distribuye como un marketplace de un solo plugin, así que la instalación son dos pasos.

**Desde una copia local:**

```text
/plugin marketplace add /ruta/a/drupilot
/plugin install drupilot@drupilot
```

**Desde GitHub:**

```text
/plugin marketplace add thebrokenbrain/drupilot
/plugin install drupilot@drupilot
```

Tras instalar, reinicia o abre una sesión nueva para que carguen los hooks. Luego ejecuta `/drupilot-doctor` para verificar tu entorno.

> Valida el manifiesto del plugin localmente cuando quieras con `claude plugin validate /ruta/a/drupilot`.

---

## Inicio rápido

```text
# 1. Comprueba lo que tienes e instala lo que falte (con confirmación)
/drupilot-doctor

# 2. Pide el port en lenguaje natural (ejecuta el flujo guiado, que pide confirmación antes de empezar)
"Porta web/modules/custom/my_module a Drupal 11"
#    …lo mismo con una palabra de modo explícita:
/drupilot web/modules/custom/my_module full
#    …o pregunta solo qué hacer a continuación (un /drupilot <ruta> a secas solo recomienda,
#    salvo que esté activo DRUPILOT_AUTONOMOUS=true: entonces se ejecuta en modo auto):
/drupilot web/modules/custom/my_module

# 3. …o conduce los pasos tú mismo:
/drupilot-setup    web/modules/custom/my_module   # sitio Drupal 11 con DDEV + toolchain
/drupilot-assess   web/modules/custom/my_module
/drupilot-port     web/modules/custom/my_module
/drupilot-refactor web/modules/custom/my_module   # Fase 2 opcional
/drupilot-test     web/modules/custom/my_module
/drupilot-contribute web/modules/custom/my_module # solo proyectos contrib
```

**También sirve un checkout suelto.** No necesitas un sitio Drupal para empezar: apunta drupilot a un checkout pelado de un módulo/tema (`/drupilot-setup ~/src/my_module`) y construye un banco de pruebas (*test-bed*) Drupal 11 en un directorio hermano, `~/src/my_module-d11/`, sin montar nunca Drupal encima de tu checkout. Por defecto el propio checkout se mueve a ese banco de pruebas, donde sigue siendo un repositorio git; `DRUPILOT_PLACEMENT=copy` o `symlink` lo deja donde está. Un módulo que ya está dentro de un sitio Drupal 11 se porta in situ. Consulta [Apuntando a un checkout suelto](#apuntando-a-un-checkout-suelto) para monorepos, la colocación y la ubicación del banco de pruebas.

---

## Comandos

| Comando | Qué hace |
| --- | --- |
| `/drupilot [ruta-del-sujeto \| --subject DIR] [full\|auto\|status\|next] [--no-confirm] [--workspace DIR] [--json]` | **Router / flujo guiado.** Detecta el estado actual (entorno, último assess, fase). Sin palabra de modo sigue tu petición: una petición de port («porta esto a Drupal 11») ejecuta `full`, mientras que un `/drupilot <sujeto>` a secas o «¿qué sigue?» solo recomienda el siguiente paso (`next`), salvo que esté activo `DRUPILOT_AUTONOMOUS=true` (o se pase `--no-confirm`), que lo ejecuta en modo `auto`; `status` es de solo lectura. `full` expone el plan y pide confirmación antes de empezar, y de nuevo en cada elección de peso; `auto` lo ejecuta **sin intervención** (ver [Modo autónomo](#modo-autónomo-manos-fuera)). Las palabras flag son para wrappers: ver [Ejecutar bajo otra herramienta](#ejecutar-bajo-otra-herramienta-contrato-no-interactivo). |
| `/drupilot-doctor [install]` | **Verificación de requisitos.** Tabla de estado por plataforma (Docker + daemon, DDEV, git, composer/php, jq, SSH/PAT) con instrucciones de instalación e instalación asistida opcional (con confirmación), más [comprobaciones de salud](#requisitos) solo informativas (configs generadas, toolchain frente a la referencia verificada, espacio en disco, restos en el origen). |
| `/drupilot-setup [ruta-del-sujeto] [--php X.Y]` | Levanta un sitio **Drupal 11 con DDEV** (para un checkout suelto, indica su ruta: el banco de pruebas se construye a su lado), instala los add-ons (`ddev-drupal-contrib`, Selenium) y el toolchain de desarrollo de Composer (incluido `drupal/core-dev`, ajustado al core instalado, que aporta PHPUnit), y escribe `rector.php` / `phpstan.neon` / `phpcs.xml.dist` / entorno de tests desde plantillas. `--php X.Y` responde de antemano a la elección del target de PHP (gana a `DRUPILOT_CHOICE_PHP_TARGET`). Idempotente. |
| `/drupilot-assess [ruta-del-módulo-o-tema]` | Produce el **informe de viabilidad** + plan por etapas con veredicto S/M/L/XL. |
| `/drupilot-port [ruta-del-módulo-o-tema]` | **Portabilidad mínima (Fase 1).** Rector oficial + (opcional) reglas digests filtradas por target + ajustes ad-hoc + cambios manuales mínimos; deja el código compilando sin deprecaciones bloqueantes. |
| `/drupilot-refactor [ruta-del-módulo-o-tema]` | **Refactor completo (Fase 2)** (opt-in): el "estilo Drupal 11", PHPStan nivel 5–6, PHPCS limpio. |
| `/drupilot-test [ruta-del-módulo-o-tema]` | Descubre, adapta y ejecuta **toda** la suite de tests en DDEV (Selenium para JS); itera hasta verde; reporta cobertura. No admite ningún otro argumento: siempre ejecuta todas las suites y reporta cobertura. |
| `/drupilot-patch [ruta-del-sujeto] [id-del-issue]` | **Obtén el `.patch`, desacoplado de contribuir.** Offline, sin push, sin gate: un parche local de pruebas, o uno con nombre para un comentario de issue de Drupal.org. Pruébalo ya, contribuye el MR después. |
| `/drupilot-contribute [ruta-del-módulo] [id-del-issue]` | Publica a **Drupal.org**: issue fork + Merge Request (o parche legacy), en modo semi o auto. Solo invocable por el usuario; nunca expone el PAT. |
| `/drupilot-layers <dir> [plan\|run] [--layer N] [--edges all\|declared]` | **Porta un conjunto de módulos en orden de dependencias.** `plan` (solo lectura, por defecto) muestra las capas de portabilidad, los ciclos de dependencias y las dependencias no declaradas con una entrada `<proyecto>:<módulo>` propuesta y la evidencia. `run` porta una capa, módulo a módulo, con el flujo normal y luego escribe un `layer-N-report.md` consolidado. Nunca edita un `info.yml` sin tu confirmación y nunca contribuye. `--edges declared` ordena el conjunto en capas solo por las dependencias que declaran `info.yml` / `composer.json` (se guarda como `layers-declared.md`, junto al plan canónico); el valor por defecto, `all`, usa además las dependencias que el código usa de verdad. `/drupilot` sobre una carpeta así lo recomienda. |
| `/drupilot-clean [ruta-del-sujeto] [--all [dir]] [--level ddev\|vendor\|workspace] [--core-cache]` | **Libera el disco y los recursos de Docker de un banco de pruebas, conserva el trabajo.** Borra el proyecto DDEV, los árboles de Composer o el workspace derivado entero (devolviendo el módulo a su sitio), solo en bancos de pruebas que construyó drupilot; muestra el plan y pregunta antes. `--all` limpia todos los bancos de pruebas de los que drupilot tiene estado (más los que haya bajo `dir`); `--core-cache` además borra los [cores base cacheados](#core-base-cacheado). Solo invocable por el usuario. Ver [Limpiar bancos de pruebas](#limpiar-bancos-de-pruebas). |
| `/drupilot-status [ruta-del-sujeto] \| --all [dir\|fichero-de-registro\|everything]` | Resumen de solo lectura: entorno, target de PHP, fase actual, último assess, estado de tests (con el veredicto de preservación), el lock de reproducibilidad congelado y el siguiente paso sugerido. `--all` admite un ámbito: un directorio (por defecto, el actual) tabula los módulos/workspaces que hay bajo él y de los que drupilot tiene estado, un fichero de registro lista una ruta por línea, y `--all everything` tabula todos los módulos con un `state.json` en el directorio de datos de drupilot (ver [Estado por módulo](#estado-por-módulo)). |

---

## Filosofía de portabilidad en dos fases

1. **Fase 1 — Compatibilidad mínima (por defecto).** Los cambios mínimos para que el módulo/tema funcione en Drupal 11 respetando la funcionalidad original y **sin colisionar** con lo que Drupal 11 ya ofrece. Motor: `drupal-rector` + ajustes manuales puntuales. Sin cambios de arquitectura.
2. **Fase 2 — Refactor "estilo Drupal 11" (opt-in).** Una reescritura a las mejores prácticas modernas: atributos PHP 8 para plugins, inyección de dependencias, tipado estricto, cero deprecaciones, cero errores de PHPStan al nivel objetivo, cumplimiento total de `Drupal` + `DrupalPractice` y tests completos en verde.

En los flujos guiado y autónomo (`/drupilot … full|auto`), un **estudio de viabilidad** siempre se ejecuta primero como gate de decisión; si ejecutas tú los comandos de cada etapa, lanza antes `/drupilot-assess`. Si el refactor es desproporcionado (umbral configurable), `drupilot` no se niega: aun así entrega un plan de portabilidad por etapas que respeta la funcionalidad original, y te deja la decisión.

**Cómo se verifica que «se respeta la funcionalidad original».** Que la suite de tests adaptada siga en **verde es el gate de preservación** en ambas fases — ese verde es la prueba de que el comportamiento se preserva. Las adaptaciones de los tests solo cambian la *forma* del test (API de PHPUnit/Drupal), nunca *lo que verifica*; una regresión de comportamiento se arregla en el código, nunca relajando un test. Si el módulo **no tiene tests**, `drupilot` informa de que la preservación **no está verificada** (`not-verified-no-tests`) y recomienda añadirlos — no los inventa. Si hay tests pero no pueden ejecutarse (falta PHPUnit/`drupal/core-dev`, Selenium inaccesible), informa de que la preservación **no está verificada (bloqueada)** (`not-verified-blocked`) e indica el motivo — nunca una regresión falsa ni un falso «sin tests». Si los grupos que se ejecutaron están en verde pero algunos no pudieron ejecutarse (p. ej. FunctionalJavascript sin Selenium), el veredicto es **verified-partial** (una ejecución completamente en verde es `verified`). Cuando lo omitido es FunctionalJavascript sin Selenium, cuenta como superado (código 0); si PHPUnit no pudo ejecutarse en un grupo, termina con código 2 (bloqueo del entorno). En ambos casos los grupos omitidos se listan (`skipped_groups` en el resultado de los tests) y esa parte del comportamiento queda sin demostrar.

**Los fallos preexistentes no son regresiones.** Antes de que Rector toque el código, `/drupilot-port` registra la suite como **línea base** (`run-phpunit.sh --baseline`; `--baseline-from-last` promueve la última ejecución, p. ej. antes de un refactor). Cada ejecución posterior compara cada test que falla con ella: un test que fallaba antes **y** después del port es **preexistente**; un test que pasaba antes y ahora falla es una **regresión** (veredicto `regression`). Un test que falla y que la línea base no contiene en absoluto (p. ej. añadido después de ella, o de un grupo que entonces se omitió) cuenta también como regresión. Un test que falla y que la línea base nunca ejecutó *de verdad* queda **sin línea base** (*not baselined*): su grupo se interrumpió en la línea base (PHPUnit murió sin registrar resultados por test), o su fallo en la línea base solo era Drupal 11 rechazando el módulo sin portar («module 'x' is incompatible with this version of Drupal core», o una dependencia ausente). Ese fallo puede ser una regresión, así que nunca cuenta como preexistente, y deja el veredicto en **not-verified-unbaselined** (no es verde, código 3). Cuando todos los fallos son de verdad preexistentes, el veredicto es **fallos preexistentes** (`pre-existing-failures`). No es verde ni prueba nada, así que los fallos se listan en `port-report.md`, y uno que ahora falla con un mensaje distinto se marca para revisarlo. Un grupo en el que PHPUnit no ejecutó ningún test cuenta como vacío, nunca como superado.

**Los tests nuevos tienen que poder fallar (controles negativos).** Todo test que escribe drupilot (Fase 2, o un test de regresión para un arreglo) lleva un control negativo: `scripts/tests/negative-control.sh` deshace el cambio de producción que protege el test (`--revert-to REF --path FICHERO`, o un `--mutation-patch` mínimo), exige que el test se ponga en **rojo**, restaura el código y comprueba que es idéntico byte a byte (`git hash-object`), y después exige que vuelva a **verde**. Un test que sigue en verde sin su cambio es **ineficaz** y se refuerza, nunca se acepta. El script nunca muta código de test, restaura los ficheros incluso ante un error o Ctrl-C, nunca toca el veredicto de tests registrado, y sus resultados aparecen en `port-report.md` y en `/drupilot-status`. Un control matado sin más (SIGKILL, p. ej. por el tiempo límite de una herramienta) no puede restaurar nada por sí mismo: su copia de seguridad guarda un manifiesto, el siguiente control se niega a empezar sobre ella, y `negative-control.sh --subject DIR --recover` devuelve el código original.

### Anotaciones de plugins a atributos PHP 8

`scripts/analysis/convert-attributes.sh` (también `run-rector.sh --attributes`) convierte `@Block(...)`, `@QueueWorker(...)`, `@Filter(...)` y el resto de anotaciones de plugins de core en atributos con `AnnotationToAttributeRector` de drupal-rector, una regla que `palantirnet/drupal-rector` incluye pero no activa en ningún set. Escribe su propio config (`<drupal_root>/.drupilot/rector-attributes.php`, a partir de `templates/rector-attributes.php.tmpl`), así que las pasadas de Rector por defecto nunca la ejecutan.

- **Tipos soportados.** Los tipos de core y la versión menor de core que necesita cada clase de atributo están en `config/plugin-attributes.json`, verificados contra drupal/core: `Action` y `Block` desde 10.2; `Condition`, `QueueWorker`, `Filter`, `FieldFormatter`/`FieldWidget`/`FieldType`, `Layout`, `Mail`, `Constraint`, todos los tipos `Views*` y el resto de tipos de plugin desde 10.3; los tipos de entidad desde 11.1; `MigrateSource` desde 11.2. Los tipos de plugin del proyecto o de contrib (p. ej. `ExtraFieldDisplay`) se declaran en `DRUPILOT_ATTRIBUTE_PLUGIN_TYPES`.
- **Dos modos.** **keep** añade el atributo junto a la anotación (core lee el atributo a partir de la versión menor del tipo y la anotación antes de ella). **strip** elimina la anotación, pero solo en los tipos que el suelo de core declarado ya soporta.
- **El suelo de core.** `--raise-floor` reescribe `core_version_requirement` para cubrir los tipos convertidos (p. ej. `^10 || ^11` → `^10.3 || ^11`, o `^11.1` en cuanto se elimina la anotación de un tipo de entidad). Sin esa opción, el script nunca sube el suelo.
- **En el flujo.** En la Fase 1 la pasada es una pestaña **opcional** (por defecto: omitir), en modo keep y limitada a los tipos que tiene Drupal 10.3, y sube el suelo de forma explícita. En la Fase 2 es el alcance "atributos PHP 8": modo strip para `^11` y modo keep mientras se mantenga deliberadamente `^10 || ^11`.
- **Seguridad.** La pasada escribe los atributos con el nombre completo, omite los ficheros que alguien convirtió a medias a mano, y deja intacta la anotación de un plugin cuya anotación tiene una clave que el constructor del atributo no acepta (p. ej. `source_module` en `@MigrateSource`, que fallaría con "Unknown named parameter": core también conserva la anotación en esos plugins). Lee los parámetros aceptados de la clase de atributo en el core del banco de pruebas y en cada core de referencia en caché. Restaura un fichero que acaba con un atributo duplicado, no pasa `php -l` o recibe un error de PHPStan sobre un atributo convertido, y escribe con el nombre completo una constante de clase que la anotación nombraba relativa a su namespace (`type = Drupal\filter\Plugin\FilterInterface::TYPE_…`, que PHP buscaría si no dentro del propio namespace del plugin). Volver a ejecutarla no cambia nada.

### Verificar la mitad Drupal 10

El banco de pruebas solo ejecuta Drupal 11, así que un port que conserva Drupal 10 (`^10 || ^11`) se limitaría a *declararlo*. `scripts/analysis/verify-core-matrix.sh` (lo ejecuta `/drupilot-port`, y `/drupilot-refactor` mientras se conserve `^10`) analiza el módulo en cada core que declara su `core_version_requirement`.

- **Qué se ejecuta.** El mismo PHPStan (phpstan-drupal + reglas de deprecación, con las versiones exactas del banco de pruebas) y `php -l` contra un core de referencia de Drupal 10 en caché — la 10.0.x del suelo y la última 10.x para `^10`, la 10.3.x para `^10.3 || ^11` — construido una sola vez mediante `ddev exec composer` en `<drupal_root>/.drupilot/cores/` (unos 200 MB y un minuto la primera vez; nunca con el PHP de tu equipo). `php -l` también se ejecuta en el PHP más bajo que un sitio Drupal 10 puede usar con el módulo (el mínimo propio de Drupal 10, 8.1, o un suelo `require.php` más alto) en un contenedor `php:X.Y-cli`.
- **Cuándo falla una pata.** Una pata de Drupal 10 **falla** ante un error que la línea base de Drupal 11 no tiene — un `#[\Override]` en `buildRevisionCacheId()` (un método que solo declara el core 11.3+), una clase que solo trae Drupal 11.
- **El veredicto.** Una ejecución limpia deja el soporte de Drupal 10 (`d10_support`) como **verified-static**: probado por análisis estático, no ejecutando la suite en Drupal 10, y `port-report.md`, el texto del issue y `/drupilot-status` lo dicen exactamente así. Una pata de Drupal 10 que falla lo deja en **failed**, que bloquea el port en `port-summary.sh`. Un requisito sin mitad Drupal 10 (`^11`) recibe **n/a**.
- **El suelo declarado siempre se comprueba.** Es siempre una de las patas por defecto, porque una pata `10` se resuelve a la *última* 10.x y no ve una API añadida después del suelo (el atributo de plugin Block, por ejemplo, solo existe desde la 10.2). Cuando solo se ejecutaron patas 10.x más nuevas (un `--cores 10,11` explícito), una ejecución limpia se informa como **verified-static-above-floor**, con un aviso: el suelo declarado no se ha comprobado.
- **El requisito recomendado.** Nunca baja un suelo de versión menor que ya declaraste (`^10.3` pasa a `^10.3 || ^11`, no a `^10 || ^11`), y se eleva a la versión menor que trae cualquier clase de atributo de plugin que use el código.
- **Sin red.** La pata se omite y el soporte sigue como **declared-not-verified**; nunca bloquea un port.

---

## Qué es automático vs. dónde decide la IA

drupilot reparte el trabajo en dos. **Los scripts deterministas** hacen el trabajo mecánico y repetible y miden el resultado; **la IA (Claude) aporta el criterio** — revisa, decide qué aplicar, arregla lo que no es mecánico y encadena los pasos. Las decisiones de peso las sigues aprobando tú (las elecciones en pestañas).

**Lo hacen los scripts, sin IA:**

- *Tocan el código:* Rector oficial (`palantirnet/drupal-rector`), la capa Rector de digests (reglas creadas por IA, pero ejecutadas como un config congelado y fijado por versión), la pasada opcional de anotaciones → atributos (`convert-attributes.sh`), `phpcbf` (estándares de código autocorregibles) y el hook `PostToolUse` (pasa `phpcbf` en cada fichero Drupal que editas).
- *Solo miden / informan:* `phpcs` (reporta lo que `phpcbf` no pudo arreglar), PHPStan (deprecaciones + errores de tipo), el gate de requisitos de preflight, la detección de PHP/core, el panel de preparación de dependencias, las **comprobaciones de seguridad del port** (`check-port-safety.sh`: un `create()` sin `ContainerFactoryPluginInterface`/`ContainerInjectionInterface` en su ascendencia real, un `use` eliminado que sigue referenciado, `new self(` en `create()`, closures bajo claves de callback de la Form/Render API, propiedades `private`/`readonly` en clases que se serializan, `#[\Override]` mientras el rango de core incluya Drupal 10, discrepancias de mayúsculas en nombres de clase — cada una atribuida al port o preexistente vía git), el **análisis de cambios de firma de core** (`scan-signature-changes.sh`: el módulo comparado con un catálogo verificado de cambios de firma de Drupal 10 → 11 en el core más bajo que declara — una subclase de `ConfigFormBase`/`ContentTranslationController` que pasa menos argumentos de los necesarios al constructor, un `getOriginal()`/`setOriginal()`/`buildRevisionCacheId()` propio que core añade en 11.2/11.3, un `hook_entity_operation()`/`_alter()` que exige el parámetro que solo pasa 11.3, un `#[\Override]` en un método que no existe en los cores declarados más antiguos), el **clasificador de deprecaciones** (`classify-deprecations.sh`: separa las deprecaciones de PHPStan en *duras* — eliminadas en una major ≤ la objetivo, p. ej. `user_roles()`, que desaparece en 11.0 — y *blandas* — eliminadas solo en una major posterior, p. ej. `user_load_by_name()`/`text_summary()`/`check_markup()`, deprecadas en 11.4 y eliminadas en 13.0 — e indica qué hace `DRUPILOT_SOFT_DEPRECATIONS` con cada una), la **matriz de cores** (`verify-core-matrix.sh`: PHPStan + `php -l` en cada core que declara el módulo, p. ej. un core de referencia de Drupal 10 en caché junto al banco de pruebas de Drupal 11), el **lint de metadatos** (`lint-extension-metadata.sh`: configuración sin `config/schema`, ajustes de plugins sin su schema, una ruta de `configure:` que ningún fichero de rutas define, clases de servicio huérfanas o con mayúsculas distintas, `arguments:` que no casan con el constructor, submódulos cuyo `core_version_requirement` no admite Drupal 11, dependencias que el código usa y `dependencies:` no declara), las **capas de portabilidad** (`layers.sh`: el orden topológico de un conjunto de módulos, sus ciclos y sus dependencias no declaradas) y los generadores de parche e informes. Estos **nunca tocan tu código**.
- *Cambian metadatos, de forma determinista:* `set-core-requirement.sh` escribe el `core_version_requirement` elegido en el `info.yml` principal **y en el de cada submódulo**. Quita una clave obsoleta `core: 8.x` y solo actualiza un módulo de tests cuando no admite Drupal 11.

**Dónde actúa la IA:**

- **Revisa cada dry-run de Rector** y decide si aplicarlo — nunca aplica a ciegas.
- **Elige qué reglas digests aplicar**, pre-marcando las que elevarían tu suelo de core en silencio.
- **Arregla lo que Rector no cubre** — genera una regla ad-hoc o edita a mano (`DRUPILOT_GENERATE_RULES`).
- **Hace los cambios manuales que Rector no puede** — `core_version_requirement`, `require.php`, Twig 3, CKEditor 5, jQuery UI.
- **Conduce el bucle de validación** — lee lo que reportan `phpcs` / PHPStan y lo arregla hasta dejarlo limpio.
- **Adapta los tests** a D11; ante un fallo de comportamiento arregla el **código**, nunca el test.
- **Reescribe al "estilo Drupal 11"** en la Fase 2 — atributos, inyección de dependencias, tipados estrictos, eliminación de deprecaciones.
- **Propone las decisiones de peso** (target de core, alcance del refactor, contribuir o no) — eliges tú.
- **Aprende de cada port** — comprueba el siguiente módulo contra los fallos que ya sufrieron los ports anteriores del proyecto, y registra los nuevos con un detector y el arreglo (`patterns.sh`).
- **Registra cada desviación en el momento** — cada cambio de Rector que revierte, cada veredicto de script que descarta, cada paso que omite, con su porqué (`log-decision.sh`), para que el informe nunca presente como conservada la salida de una herramienta que no lo fue.

**Cuándo actúa la IA — el patrón.** La IA es el director de orquesta: los scripts no se llaman entre sí. La IA ejecuta uno, lee su salida, decide el siguiente y lo ejecuta. Así que actúa **antes** de cada script (decidir si lo lanza y cómo) y **después** de él (leer el resultado y arreglar lo que queda), además de en las pestañas de decisión. La única excepción es el **hook `PostToolUse`**, que pasa `phpcbf` por su cuenta tras cada edición de fichero — sin IA en el bucle.

**Los hooks — automáticos, los dispara el harness.** Los hooks son scripts deterministas que **dispara el propio Claude Code ante un evento** — ni la IA ni tú los invocáis. El hook es el automatismo; la IA o tú sois los *destinatarios* de lo que decide:

| Hook | Cuándo actúa | Qué hace | Su salida va |
| --- | --- | --- | --- |
| `session-detect-env` | al iniciar la sesión | resume tu entorno + target de PHP | a la **IA** (como contexto) |
| `post-edit-lint` | tras cada edición de fichero (Write/Edit) | ejecuta `phpcbf` → **edita el fichero**, luego reporta lo que queda | a la **IA** (para corregir el resto) |
| `guard-contrib` | antes de cada comando Bash | detecta un `git push` / MR hacia el exterior, o un `git commit` que se salta los git hooks activos del repositorio (`--no-verify` / `-n`) | **a ti** (pide confirmación) |

Así que un hook nunca es IA ni una decisión humana en sí mismo — es el automatismo. `post-edit-lint` es el único trozo que cambia código del todo por su cuenta; `guard-contrib` es un automatismo cuyo único propósito es volver a meterte **a ti** en el bucle antes de que algo salga de tu máquina. Actívalos/desactívalos con `DRUPILOT_POST_EDIT_LINT`, `DRUPILOT_SESSION_CONTEXT` y `DRUPILOT_HOOKS_GUARD` (la comprobación de los commits que se saltan los hooks; ver [Configuración](#configuración)); la protección de push/MR siempre pregunta en modo `semi`, en cualquier ejecución autónoma y siempre que esté puesto `DRUPILOT_NONINTERACTIVE=1`.

---

## Modo autónomo (manos fuera)

Basta describir lo que quieres en lenguaje natural — **"porta este módulo a Drupal 11"** ya ejecuta el flujo completo (guiado, con confirmaciones) a través del `drupal-port-orchestrator`, que delega en los subagentes especialistas (`drupal-viability-analyst`, `drupal-test-engineer`) según haga falta. ¿Lo quieres **totalmente desatendido** (sin ninguna confirmación)? Usa la palabra de modo `auto` (o pon `DRUPILOT_AUTONOMOUS=true`): entonces ejecuta **setup → assess → port → refactor → test** sin intervención — sin confirmación inicial, generando el `.patch` local al final.

```text
# El lenguaje natural basta — esto dispara el orquestador:
"Porta el módulo del directorio actual a Drupal 11, hazlo todo de forma autónoma"

# …o explícitamente:
/drupilot web/modules/custom/my_module auto
```

Dos cosas que conviene saber — son límites de seguridad deliberados:

1. **Nunca contribuye por su cuenta.** El modo autónomo se detiene antes de cualquier acción hacia el exterior: ni `git push`, ni Merge Request, ni `/drupilot-contribute`. Si el módulo es contrib, solo *sugiere* contribuir al final. Publicar sigue siendo un paso explícito y aparte que ejecutas tú.
2. **Dos capas de "sin preguntas".** La palabra de modo `auto` solo relaja las *comprobaciones propias* de drupilot. Bash/Edit/Write siguen pasando por el sistema de permisos de Claude Code, así que una ejecución realmente desatendida necesita además un modo de permisos permisivo:

```bash
# Interactivo pero desatendido (acepta las ediciones automáticamente):
claude --permission-mode acceptEdits

# Totalmente headless (CI / scripts):
export DRUPILOT_AUTONOMOUS=true
export DRUPILOT_GENERATE_RULES=auto    # el orquestador ya lo trata como auto en este modo
claude -p "/drupilot web/modules/custom/my_module auto" --permission-mode bypassPermissions
```

En modo autónomo `DRUPILOT_GENERATE_RULES` se trata como `auto` (ponlo en `off` para que la generación de reglas ad-hoc se quede en solo-informar). Todo sigue pasando por sus comprobaciones previas y es idempotente: un requisito duro ausente detiene esa etapa limpiamente, y reejecutar salta el trabajo ya hecho. Ten en cuenta que `DRUPILOT_AUTONOMOUS=true` (exportada o guardada en `.drupilot.json`) convierte también un `/drupilot <sujeto>` a secas, sin palabra de modo, en una ejecución sin intervención; desactívala, o pasa explícitamente `next` o `status`, cuando solo quieras una recomendación. En cambio, `full` ejecuta el mismo pipeline pero **se detiene a pedir tu confirmación** y deja refactor/contribución como opt-in.

---

## Ejecutar bajo otra herramienta (contrato no interactivo)

Un wrapper (otra skill, un job de CI, un script que conduce `claude -p`) necesita entradas estables y un resultado legible por máquina, no prosa. El contrato:

| Entrada | Variable de entorno (canónica) | Palabra del router (azúcar) | Flag de script |
| --- | --- | --- | --- |
| El sujeto | — | primera palabra posicional, `/drupilot <dir> …`, o un `--subject DIR` al principio | `--subject DIR` (todo script que trabaja sobre un módulo; `layers.sh` usa `--dir`, `run-upgrade-status.sh` usa `--module NAME`, y los scripts de Drupal.org `find-upstream-issue.sh` / `issue-fork.sh` / `open-mr.sh` / `check-prereqs.sh` reciben el nombre de máquina del proyecto con `--project NAME`) |
| Dónde va el banco de pruebas de un sujeto suelto | `DRUPILOT_WORKSPACE_DIR=DIR` | `--workspace DIR` | `--workspace DIR` (`resolve-workspace.sh`, `ddev-up.sh`, `place-subject.sh`; el flag gana a la variable) |
| No preguntar nunca | `DRUPILOT_NONINTERACTIVE=1` | `--no-confirm` (también selecciona `auto`) | — |
| Pipeline sin intervención | `DRUPILOT_AUTONOMOUS=true` | `auto` | — |
| Pre-responder una elección con pestañas | `DRUPILOT_CHOICE_<KEY>=valor` (ver [Pre-responder elecciones en pestañas](#pre-responder-elecciones-en-pestañas)) | — | `scripts/env/choice.sh --key KEY --json` |
| Resultado para máquinas | — | `--json` | `port-summary.sh --subject DIR --json` |

- `DRUPILOT_NONINTERACTIVE=1` hace que todos los scripts se comporten como si no hubiera terminal: no se muestra ninguna pregunta y cada una toma su **valor por defecto**, la respuesta recomendada y segura (mover el módulo al banco de pruebas se hace; un push o una limpieza destructiva, no). `DRUPILOT_ASSUME_YES=1` es distinto: responde **sí** a las confirmaciones sí/no de los scripts, haya o no terminal, y una elección entre varias opciones toma su valor por defecto; solo el borrado destructivo de `/drupilot-clean` sigue necesitando `--yes` o una respuesta interactiva. Úsalo solo cuando eso es lo que quieres.
- `--no-confirm` nunca convierte una ejecución en una acción hacia fuera: como `auto`, nunca hace push, abre un Merge Request ni contribuye. El hook `guard-contrib` lo garantiza: siempre que `DRUPILOT_NONINTERACTIVE=1` esté en su entorno o preceda al comando, pregunta antes de cualquier comando de push o de Merge Request, incluso con `DRUPILOT_CONTRIB_MODE=auto`.
- Con `--json`, el mensaje final del router es exactamente el JSON de `scripts/analysis/port-summary.sh`. Un wrapper también puede ejecutar ese script por su cuenta, lo que es más robusto que leer la respuesta del modelo.

```bash
# Port headless con un resultado legible por máquina:
export DRUPILOT_NONINTERACTIVE=1
claude -p "/drupilot ~/src/my_module auto --no-confirm --workspace ~/src/my_module-d11 --json" \
  --permission-mode bypassPermissions > result.json

# O lee el resultado directamente de los registros de drupilot (sin modelo):
bash "$CLAUDE_PLUGIN_ROOT/scripts/analysis/port-summary.sh" --subject ~/src/my_module-d11/web/modules/custom/my_module --json
```

`port-summary.sh` solo compone lo que drupilot registró (el `state.json` por módulo, el manifiesto del port, el registro de decisiones, la última ejecución de tests, la matriz de cores) y nunca inventa un valor: lo desconocido es `null`. `port-report.sh` también lo guarda como `.drupilot/port-summary.json` junto a `port-report.md` (en una ejecución de `/drupilot-layers`, donde varios módulos comparten un mismo banco de pruebas, ambos van a `.drupilot/modules/<machine>/` para no sobrescribirse entre sí). Sus campos principales:

| Campo | Significado |
| --- | --- |
| `schema_version` | `1`. Dentro de una versión pueden añadirse campos; renombrar o quitar uno la incrementa. |
| `status` | `not-started`, `setup`, `assessed`, `ported`, `refactored`, `tested`, `contributed`, o `blocked` (ver `blockers`). |
| `blockers` | `[{source, reason}]`: por qué un módulo portado está `blocked` — una regresión de tests, tests que no pudieron ejecutarse o que nunca tuvieron línea base, una pata de la matriz de cores fallida, o errores de port-safety/firmas. Un resultado de tests o de la matriz de cores calculado sobre fuentes anteriores se muestra pero nunca bloquea; los errores de port-safety/firmas vienen del manifiesto del port y bloquean hasta que un registro de port posterior los elimine. |
| `effort` | El veredicto del assess: `S`, `M`, `L` o `XL`. |
| `core_version_requirement`, `require_php`, `d10_support` | Lo que declara ahora el módulo, y cómo se verificó su mitad Drupal 10. `d10_support` es `verified-static`, `verified-static-above-floor`, `declared-not-verified`, `failed` (falló una pata de Drupal 10: bloquea cuando viene de una matriz de cores reciente), `n/a` (sin mitad Drupal 10, p. ej. `^11`) o `null` si se desconoce (ver [Verificar la mitad Drupal 10](#verificar-la-mitad-drupal-10)). |
| `d10_support_source` | De dónde sale `d10_support`: `core-matrix` (una matriz ejecutada sobre el código actual, que también decide el bloqueo por matriz de cores) o `manifest`. |
| `files_changed` | Ficheros que cambió el port (el recuento del manifiesto, si no, los ficheros del parche). |
| `rector_rules` | `[{rule, hits, passes}]`: reglas de Rector que cambiaron ficheros. |
| `reverted_rules` | Cambios de Rector deshechos a mano, con el porqué. |
| `manual_fixes` | Ediciones manuales, con el porqué y un change record. También `post_port_fixes`, `behavior_changes`, `preexisting_bugs`, `tooling_deviations`, `test_adaptations`, `deferred`. |
| `preservation` | `{verdict, status, executed, tests_failed, fresh, recorded_at}` de la última ejecución de tests. `verdict` es uno de `verified`, `verified-partial`, `regression`, `pre-existing-failures`, `not-verified-unbaselined`, `not-verified-blocked` o `not-verified-no-tests`. `regression`, `not-verified-blocked` y `not-verified-unbaselined` dejan `status` en `blocked`, pero solo cuando el módulo ya está en `ported` o en una etapa posterior, y salvo que se sepa que el resultado de los tests está desfasado (`fresh: false`, calculado sobre código anterior); un resultado de vigencia desconocida también bloquea. |
| `matrix` | `{verdict, d10_support, fresh, generated_at}` de la matriz de cores. |
| `patch` | `{path, kind, at, exists}` del último parche. |
| `reports` | Rutas de `port-report.md`, `viability-report.md`, `decisions.md` y `port-summary.json`. |

`--strict` hace que el script salga con 3 cuando el estado es `blocked`, para un gate de CI. El esquema completo está en la cabecera del script.

---

## Espacios de trabajo, salidas y estado

Dónde construye drupilot su banco de pruebas Drupal 11, qué escribe para que lo leas, qué guarda para sí mismo y cómo liberar el disco después.

### Apuntando a un checkout suelto

No necesitas un sitio Drupal para empezar. Apunta drupilot a un checkout pelado de un módulo/tema y construye un **banco de pruebas Drupal 11 en un directorio hermano** `<padre>/<machine_name>-d11/`, colocando el sujeto bajo `web/modules/custom/<machine_name>` (los temas van a `web/themes/custom/...`). **drupilot nunca monta Drupal encima de tu checkout**, así que sus ficheros y su `composer.json` nunca se mezclan con los de un sitio. Por defecto (`DRUPILOT_PLACEMENT=move`) el propio checkout se mueve a `<padre>/<machine_name>-d11/web/modules/custom/<machine_name>`, donde sigue siendo un repositorio git con todas sus ramas; `copy` deja el original intacto, y `symlink` lo deja en su sitio y lo enlaza. `/drupilot-clean --level workspace` devuelve a su sitio un checkout movido.

```text
padre/
├── my_module/                 # tu checkout (se mueve al banco de pruebas por defecto; se queda aquí con copy/symlink)
└── my_module-d11/             # el banco de pruebas que construye drupilot
    ├── .drupilot/             # salidas para el desarrollador, visibles e ignoradas en git
    └── web/modules/custom/my_module   # el checkout movido (o su copia / enlace)
```

Cómo llega el sujeto ahí lo controla `DRUPILOT_PLACEMENT` (`move` / `symlink` / `copy`); la ubicación del banco de pruebas, `DRUPILOT_WORKSPACE_DIR` (ver [Configuración](#configuración)). Un módulo que **ya está dentro** de una raíz de Drupal conserva ese layout — esto solo aplica a checkouts sueltos. Portar in situ usa el core de ese mismo sitio, así que el sitio **ya tiene que estar en Drupal 11**; `resolve-workspace.sh` avisa cuando no lo está (`in_place_ok: false`), y fijar `DRUPILOT_WORKSPACE_DIR` en un directorio fuera del sitio hace entonces el port en un banco de pruebas Drupal 11.

**Un módulo dentro del repositorio de un proyecto (monorepo).** Un clon de un proyecto Drupal basado en Composer no suele tener core: `web/core` y `vendor/` están en el `.gitignore`. drupilot reconoce esa **raíz de proyecto sin core instalado** (un `composer.json` que requiere `drupal/core-recommended` o `drupal/core`, con un docroot `web/`) y nunca construye un banco de pruebas dentro de tu repositorio: todos los módulos del proyecto van a un banco de pruebas a su lado, `<padre>/<proyecto>-d11/` (un módulo en un repositorio git que no es un proyecto Drupal recibe `<padre del repositorio>/<machine_name>-d11/`). Un módulo que es un subdirectorio de un repositorio nunca se **mueve** (eso lo borraría de tu repositorio): `move` pasa a ser `copy`. Una copia recibe una línea base de git: su propio repositorio, cuyo primer commit es el módulo tal como está confirmado en tu repositorio. Así, `make-patch.sh --local` escribe el mismo `<name>-port-to-drupal-11.patch` relativo al módulo que para un módulo suelto, más `<name>-port-to-drupal-11-repo.patch` con rutas relativas a la raíz de tu repositorio (`web/modules/custom/<name>/...`), que se aplica allí con `git apply`. Con una copia, en tu repositorio nunca se escribe nada (`origin-hygiene.sh --check` lo demuestra). Un `DRUPILOT_PLACEMENT=symlink` explícito se respeta: el banco de pruebas enlaza entonces el módulo dentro de tu repositorio, así que el port lo edita ahí.

```text
padre/
├── site/                      # tu monorepo — sin tocar (sin web/core instalado)
│   └── web/modules/custom/acme_core
└── site-d11/                  # el banco de pruebas compartido que construye drupilot
    └── web/modules/custom/acme_core   # una copia con línea base de git
```

**Higiene del origen.** Antes de colocar el sujeto, drupilot registra el `git status` del checkout de origen (estado oculto, nunca dentro del árbol); `scripts/env/origin-hygiene.sh --check` informa después de cualquier entrada nueva sin seguimiento atribuible a drupilot (`.ddev/`, `vendor/`, `node_modules/`, `.phpstan-cache/`, configuración generada, parches, enlaces simbólicos que salen del árbol) — solo informa, nunca borra nada — y el informe del port muestra el resultado. Una colocación `copy` no copia los restos sin seguimiento del entorno local (`.ddev/`, `vendor/`, `.drupilot*`, `.phpstan-cache/` en la raíz, `node_modules/` a cualquier profundidad) y descarta los enlaces simbólicos sin seguimiento que apuntan fuera del checkout; todo lo que git sigue (una librería `vendor/` incluida en el módulo, un enlace simbólico confirmado) se copia siempre (`--no-exclude` recupera la copia literal). Los ficheros propios de drupilot dentro de tu repo (el `.drupilot.json` del lado del sujeto, el parche local) se ocultan mediante el `.git/info/exclude` **local** del repo, nunca con su `.gitignore` versionado.

### La carpeta `.drupilot/`

Las salidas destinadas al desarrollador viven en un único directorio **visible e ignorado en git** `.drupilot/` en la raíz de Drupal:

- **Informes para ti:** el **boletín** del port (`port-report.md`) y su resumen legible por máquina (`port-summary.json`) — en una ejecución de `/drupilot-layers`, donde varios módulos comparten un mismo banco de pruebas, la pareja de cada módulo va en su lugar a `.drupilot/modules/<machine>/` —, el **informe de viabilidad** (`viability-report.md`), el HTML de cobertura de tests, los planes de capas (`layers.md`, y `layers-declared.md` con `--edges declared`) y los informes consolidados por capa (`layer-N-report.md`), el **registro de decisiones** (`decisions.md`, con su gemelo para máquinas `decisions.jsonl`) y el **catálogo de patrones aprendidos** (`patterns.json`).
- **Ficheros de las herramientas:** `backups/` (las copias anteriores de las configuraciones que sustituyó un nuevo renderizado o `run-rector.sh`), `rector-attributes.php` (la configuración de Rector de la pasada de atributos) y `cores/` (los cores de referencia de Drupal 10 de la matriz de cores, en caché, de unos 200 MB cada uno).

El parche local no está aquí: se escribe junto al módulo y se oculta mediante el `.git/info/exclude` de su repositorio. La carpeta se ignora en git automáticamente para que nunca acabe en tu parche, y puedes apuntarla a otro sitio con `DRUPILOT_ARTIFACTS_DIR` (los informes y `backups/` se mueven con ella; `cores/` y `rector-attributes.php` se quedan siempre en `<drupal_root>/.drupilot/`). `/drupilot-clean` conserva los informes; una limpieza `workspace` los copia fuera del banco de pruebas, pero no `cores/`, que libera. Una excepción: un módulo o carpeta que pertenece a un repositorio mayor y aún no tiene una raíz de Drupal utilizable (un clon de monorepo, una carpeta de módulos dentro de otro repositorio, antes del setup) guarda estas salidas en su directorio de estado oculto (`<state>/artifacts`, los scripts imprimen la ruta), así que no se escriben en ese repositorio. El catálogo de patrones aprendidos no sigue esa regla: para ese módulo o conjunto vive en el nivel superior del repositorio, `<repositorio>/.drupilot/patterns.json`, en una carpeta `.drupilot/` que se ignora a sí misma en git (ver [Patrones aprendidos](#patrones-aprendidos)). La caché legible por máquina y el lockfile de determinismo se quedan deliberadamente **ocultos bajo `$HOME`** para que no puedan filtrarse a un parche: en el directorio de datos de drupilot, `~/.local/share/drupilot` (`$XDG_DATA_HOME/drupilot`), o donde apunte `DRUPILOT_HOME`. Los hooks y los scripts usan ese mismo directorio.

### Registro de decisiones

Cada punto en el que un port no conserva lo que produjo una herramienta, o no sigue el flujo, queda registrado en el momento en que ocurre con `scripts/analysis/log-decision.sh`, con **qué** y **por qué**: un cambio de Rector revertido o reescrito a mano, el veredicto de un script descartado, un paso omitido, un arreglo hecho después de que la validación o los tests detectaran un problema, un test al que se le cambió la forma, un bug previo que se deja sin arreglar, un cambio de comportamiento que un revisor debe comprobar. Cada entrada es una línea JSON en `.drupilot/decisions.jsonl` (un registro por raíz de Drupal; cada entrada indica su módulo), y `decisions.md`, a su lado, se regenera como una tabla por módulo. El informe de port y el de capa combinan estas entradas con los campos estructurados del manifiesto del port (`rector_rules`, `rector_reversions`, `post_port_fixes`, `preexisting_bugs`, `behavior_changes`, `tooling_deviations`, `validation`), de modo que las reglas de Rector revertidas y los arreglos post-port se suman entre módulos y capas. `log-decision.sh --subject <dir> --list` muestra las entradas de un módulo.

### Patrones aprendidos

Los mismos fallos suelen repetirse de un módulo a otro. drupilot mantiene un **catálogo de patrones aprendidos** por proyecto, `.drupilot/patterns.json` en la raíz de Drupal (`scripts/analysis/patterns.sh`). Un módulo o conjunto dentro de un repositorio mayor que aún no tiene raíz de Drupal (un monorepo, antes del setup) lo guarda en cambio en el nivel superior del repositorio, `<repositorio>/.drupilot/patterns.json`, que se ignora a sí mismo en git. Cada entrada es un fallo que ya sufrió un port anterior: un **detector** (una ERE POSIX que se pasa sobre el código y/o una regla determinista como `port-safety:fapi-callable` o `signature:entity-get-original`, que reutiliza `check-port-safety.sh` / `scan-signature-changes.sh`), el **arreglo** que funcionó, por qué hizo falta, el módulo y la capa de donde se aprendió, y cuántas veces se ha registrado (`hits`).

- **Antes** de un port o un refactor, `patterns.sh scan --subject <dir>` ejecuta todos los detectores sobre el módulo intacto; cada coincidencia pasa a ser un punto que hay que comprobar, de modo que el fallo se previene en vez de repararse.
- **Al final**, `patterns.sh harvest` lista candidatos (los cambios de Rector revertidos y los arreglos post-port del manifiesto y del registro de decisiones), tú eliges cuáles conservar y `patterns.sh add` los registra. Un id existente se actualiza en su sitio: sus `hits` suben y el módulo se añade a `seen_in`. Las ejecuciones autónomas solo registran detectores que han comprobado y los listan para revisión.
- `/drupilot-layers` comparte un único catálogo para todo el conjunto, así que lo que aprendió la capa N se comprueba en la capa N+1, aunque cada módulo tenga su propio banco de pruebas.
- `patterns.sh export` imprime las entradas en el formato de `config/deprecations.json`, listas para proponerlas upstream (sin los nombres de módulo salvo con `--with-source`).

El catálogo es JSON plano, pensado para leerlo y editarlo a mano (`patterns.sh list`, `patterns.sh remove --id <id>`). Como el resto de `.drupilot/`, está ignorado en git. Apunta `DRUPILOT_PATTERNS_FILE` a un fichero versionado para compartirlo con un equipo.

### Estado por módulo

drupilot guarda un registro por módulo/tema, `state.json`, en el mismo directorio de estado oculto que `assess.json` y `last-test.json`: qué etapas se alcanzaron y cuándo, y una instantánea de lo que necesita una vista de cartera. Es estado de máquina, así que está oculto a propósito: sobrevive a un `git clean` o a un banco de pruebas reconstruido (si no, el siguiente paso volvería a empezar en `/drupilot-port`), nunca puede filtrarse a un parche, y un único directorio de datos contiene el registro de todos los módulos, así que `/drupilot-status --all everything` los encuentra todos sin recorrer tus árboles de proyecto. La carpeta visible `.drupilot/` guarda los informes para personas; el registro se presenta bajo demanda.

Lo escribe el flujo, no la memoria: `port-report.sh` registra `ported` / `refactored` (según la fase del manifiesto), `run-phpunit.sh` registra `tested` tras una ejecución de toda la suite cuya preservación es `verified` o `verified-partial` y lleva el veredicto de cada ejecución registrada, `verify-core-matrix.sh` y `make-patch.sh` añaden su veredicto y su parche, y `/drupilot-setup`, `/drupilot-assess` y `/drupilot-contribute` registran `setup`, `assessed` y `contributed` mediante `scripts/env/state.sh record`. Lo leen `next-step.sh` (el router y `/drupilot-status`) y el hook post-edición.

| Clave | Significado |
| --- | --- |
| `schema` | Versión del registro (`1`). |
| `subject`, `machine_name`, `type` | El directorio del módulo/tema (absoluto), su nombre de máquina y su tipo. |
| `drupal_root`, `ddev_project` | El banco de pruebas (workspace) en el que vive y el nombre de su proyecto DDEV. |
| `origin`, `placement` | El checkout del desarrollador desde el que se colocó un sujeto suelto, y cómo (`move` / `symlink` / `copy`). |
| `stage`, `stages` | La etapa más alta alcanzada (`setup` < `assessed` < `ported` < `refactored` < `tested` < `contributed`; nunca baja sin `DRUPILOT_STATE_FORCE`) y la hora en que se registró por última vez cada etapa. |
| `effort`, `assessed_at` | El veredicto S/M/L/XL del assess y cuándo se hizo. |
| `git` | `branch`, `commit` y `dirty` (cambios sin confirmar) del checkout del sujeto. |
| `toolchain` | Del lock: `drupal_core`, `php_target`, `core_strategy`, `packages` (versiones de Rector, drupal-rector, PHPStan, coder, Drush, core-dev). |
| `tests` | La última ejecución de PHPUnit registrada: `status`, `preservation`, `executed`, `tests_failed`, recuentos por grupo, `recorded_at` y `fresh` (calculado sobre las fuentes actuales). |
| `core_matrix` | La última matriz de cores: `verdict`, `d10_support`, `generated_at`, `fresh`. |
| `patch` | El último parche generado: `path`, `kind` (`local` / `issue` / `contribution`), `at`. |
| `portfolio` | Se rellena cuando el módulo lo porta `/drupilot-layers`: `dir` (el conjunto) y `layer` (su capa de portabilidad); lo escribe `state.sh record\|refresh --portfolio DIR --layer N`. |
| `created`, `updated`, `drupilot_version` | Marcas de tiempo del registro y el drupilot que lo escribió por última vez. |

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" show --subject web/modules/custom/foo   # un módulo, combinado con los veredictos actuales
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --json                              # todos los registros del directorio de datos de drupilot
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --root ~/drupal-ports --json       # todos los módulos bajo un directorio de workspaces
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --registry ports.txt               # una ruta por línea (dirs de módulo o dirs a escanear)
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" record --subject web/modules/custom/foo --stage assessed --effort M
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" refresh --subject web/modules/custom/foo --portfolio web/modules/custom --layer 2
```

`show` y `list` son de solo lectura (nunca crean un directorio de estado); la tabla va a stderr y `--json` pone el payload en stdout. Un módulo portado antes de que existiera este registro sigue apareciendo con `--root` o `--subject`, con su etapa derivada de sus registros anteriores.

### Limpiar bancos de pruebas

Un banco de pruebas ocupa un proyecto DDEV (contenedores, volúmenes, una base de datos) y unos cientos de MB de árboles de Composer. `/drupilot-clean` (`scripts/env/clean.sh`) los libera **sin perder el trabajo**: los informes de `.drupilot/`, el estado oculto (`state.json`, `assess.json`, el lockfile), los parches locales y el checkout git del módulo con todas sus ramas se conservan siempre. Primero muestra el plan y solo actúa cuando confirmas (`--yes` en un script; ni `DRUPILOT_ASSUME_YES` ni el modo autónomo lo implican).

| Nivel | Elimina |
| --- | --- |
| `ddev` | El proyecto DDEV: `ddev delete -Oy` (contenedores, volúmenes, base de datos; sin snapshot). El código y `.ddev/` se quedan. |
| `vendor` (por defecto) | Además `vendor/` y cada ruta de instalación de Composer (core, contrib, librerías, recipes); nunca una ruta `*/custom`. |
| `workspace` | Además el banco de pruebas entero. Un módulo colocado con `move` vuelve primero a la ruta de la que vino (se rechaza si esa ruta ya no está vacía), un `symlink` solo se desenlaza, y una `copy` solo se descarta si no contiene nada que falte en su origen (mismo commit, árbol limpio y ninguna rama, tag o stash que solo tenga la copia) o con `--discard-copies`. Antes se copian los informes de `.drupilot/` del banco de pruebas (no su caché `cores/`) al `.drupilot/` del propio módulo (para un módulo de un repositorio mayor, como un monorepo, a su directorio de estado oculto, junto con los parches de una copia descartada) o, si ningún módulo tiene un origen al que copiarlos, al directorio de estado oculto de la raíz (`reports-<hora>`). |

Solo elimina `vendor/` o un workspace de un **banco de pruebas de drupilot**: una raíz que construyó `ddev-up.sh`, que la marca en el `.drupilot.json` de la raíz (`drupilot_testbed`, con el origen de cada módulo que colocó `place-subject.sh`). Un banco de pruebas construido antes de que existiera esa marca se reconoce por su nombre por defecto `<nombre>-d11` y su `DRUPILOT_WORKSPACE_DIR`; como un sitio existente elegido con `--workspace` puede parecer igual, esa raíz necesita `--foreign-ok` para `ddev` y `vendor` (y vuelve a preguntar) y nunca se elimina entera. En cualquier otra raíz de Drupal (tu propio sitio) solo se permite `--level ddev --foreign-ok`, y vuelve a preguntar porque borra la base de datos de ese sitio. `--all` limpia todos los bancos de pruebas de los que drupilot tiene estado (más los que haya bajo `--scan DIR`); `--core-cache` además borra los [cores base cacheados](#core-base-cacheado).

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/clean.sh" --subject web/modules/custom/foo --dry-run           # el plan (nivel vendor)
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/clean.sh" --subject ../foo --level workspace --yes --json      # borra el banco de pruebas entero y devuelve foo a su sitio
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/clean.sh" --all --scan ~/drupal-ports --level ddev --dry-run   # el proyecto DDEV de cada banco de pruebas
```

Después, el `state.json` de cada módulo registra `environment: {status: "removed", level}`, y el siguiente paso es `/drupilot-setup`, que reconstruye lo eliminado: `ddev-up.sh` ejecuta `ddev composer install` cuando hay `composer.json` pero no `vendor/`, y vuelve a crear un workspace eliminado con la versión de core que congeló el lockfile.

### Core base cacheado

Tras un `composer create-project` nuevo, `ddev-up.sh` guarda el árbol resultante (ficheros de Composer, `vendor/`, core, `recipes/`; nunca `.ddev/`, `settings*.php` ni `files/`) en el directorio de datos de drupilot, con clave por target de PHP y versión exacta de core. El siguiente setup de una raíz vacía lo copia (copy-on-write donde el sistema de ficheros lo permite: `cp --reflink=auto` en btrfs/XFS, `cp -c` en APFS; si no, una copia normal) y lo comprueba con `ddev composer install`; si falla, la entrada se descarta y el setup ejecuta `create-project` como antes. "Vacía" es estricto: además de los dotfiles, la raíz solo puede tener un docroot que no contenga más que los `settings*.php` que genera DDEV. Un docroot que ya tiene cualquier otra cosa (un sitio sin Composer con la estructura `<raíz>/web`, una ejecución anterior a medias) nunca se sobrescribe con la caché, nunca se guarda en caché ni se marca como banco de pruebas, y una comprobación fallida solo elimina lo que añadió la copia. Ahorra aproximadamente un tercio del tiempo de setup: la caché compartida de Composer de DDEV ya evita las descargas, así que la ganancia es el trabajo de instalación y scaffold. Se controla con `DRUPILOT_CORE_CACHE` (ver [Configuración](#configuración)).

---

## Configuración

Los valores por defecto están en `config/defaults.json`. **Cada clave `DRUPILOT_*` puede sobrescribirse con una variable de entorno del mismo nombre** (la variable de entorno siempre gana). Un **`.drupilot.json`** por proyecto en la raíz de Drupal se lee **entre** el entorno y los valores por defecto (un valor ahí puede ser una cadena, un número o un booleano JSON: `false` significa falso) — ahí se recuerdan las elecciones en pestañas que haces (target de PHP, disposición del workspace, target de core, alcance del refactor y nivel de PHPStan, modo de contribución, sandbox de capas) para que las ejecuciones posteriores no vuelvan a preguntar. Se ignora en git automáticamente para que nunca acabe en un parche.

| Variable | Por defecto | Efecto |
| --- | --- | --- |
| `DRUPILOT_PHP_TARGET` | `8.3` | Versión de PHP destino (controla PHPStan / PHPCS / DDEV, y limita por arriba el suelo de PHP de Rector). |
| `DRUPILOT_DRUPAL_TARGET` | `^11` | Rango de core destino. |
| `DRUPILOT_CORE_TARGET_STRATEGY` | `auto` | Decisión de compatibilidad de core: `auto` (mantiene `^10 \|\| ^11` mientras sea retrocompatible, pasa a `^11` ante una ruptura BC / refactor), `d11-only` o `keep-d10`. Mantener D10 declara además un suelo composer `require.php` (ver `DRUPILOT_REQUIRE_PHP_FLOOR`), y la elección produce un veredicto SemVer de subida de versión. |
| `DRUPILOT_KEEP_D10` | _(legacy)_ | Booleano legacy (`true` → mantener D10, `false` → solo D11); solo se respeta mientras `DRUPILOT_CORE_TARGET_STRATEGY` sea `auto`, y una estrategia explícita prevalece. Prefiere `DRUPILOT_CORE_TARGET_STRATEGY`. |
| `DRUPILOT_REQUIRE_PHP_FLOOR` | `detect` | Al mantener `^10 \|\| ^11`, cómo fijar el `require.php` de composer: `detect` deriva el suelo real de un escaneo heurístico del código portado (p. ej. `>=8.1` si no usa construcciones de PHP 8.2/8.3, para soporte real de Drupal 10); `target` mantiene el conservador `>=<target de php>`. Bajar el suelo es best-effort — confírmalo con PHPCompatibility. |
| `DRUPILOT_PLACEMENT` | `move` | Cómo se coloca un checkout suelto en el banco de pruebas hermano: `move` lo reubica (sin pérdida — sigue siendo un repo git en la nueva ruta), `symlink` deja tu checkout donde está y lo enlaza (un destino fuera del banco de pruebas no es visible dentro del contenedor DDEV, así que las herramientas vía `ddev exec` no lo ven — úsalo para trabajo en el host), `copy` lo duplica sin los restos sin seguimiento del entorno local (`.ddev/`, `vendor/`, `node_modules/`, …) ni los enlaces simbólicos sin seguimiento que salen del checkout (todo lo que git sigue se copia siempre). Para un módulo que es un subdirectorio de un repositorio (un monorepo), `move` pasa a ser `copy` (moverlo lo borraría del repositorio); `symlink` y `copy` se respetan, y `symlink` edita entonces el módulo dentro del repositorio. |
| `DRUPILOT_WORKSPACE_DIR` | _(vacío)_ | Ruta explícita para la raíz del banco de pruebas de Drupal. Vacío significa un hermano `<padre>/<machine_name>-d11` o, para un módulo dentro de un repositorio, un banco de pruebas junto a ese repositorio (`<padre>/<proyecto>-d11` para un proyecto Drupal sin core instalado). Mantenlo fuera de tu repositorio: `resolve-workspace.sh` avisa cuando no lo está. |
| `DRUPILOT_LAYERS_SANDBOX` | _(se pregunta)_ | Se aplica a las ejecuciones de `/drupilot-layers` sobre una carpeta **suelta** de módulos (un conjunto dentro de una raíz de Drupal 11 se porta in situ, en ese único sitio; un checkout de proyecto sin core instalado usa siempre un único banco de pruebas compartido junto al repositorio). `per-module` da a cada módulo su propio banco de pruebas `<nombre>-d11`. `shared` usa un único banco de pruebas para todo el conjunto, fuera del repositorio (`shared_root` de `resolve-workspace.sh --json`), para que un módulo y los módulos de los que depende se instalen juntos. Vacío significa que el comando pregunta; las ejecuciones autónomas usan `per-module`. La respuesta se recuerda en `.drupilot.json`. |
| `DRUPILOT_ARTIFACTS_DIR` | _(vacío)_ | Override del directorio de salidas visible `.drupilot/`. Vacío significa `<raíz>/.drupilot`. |
| `DRUPILOT_HOME` | _(vacío)_ | El directorio de datos oculto de drupilot: el estado de máquina por módulo, los lockfiles y las cachés. Vacío significa `$XDG_DATA_HOME/drupilot` (`~/.local/share/drupilot`). Solo se lee del entorno; indica una ruta absoluta (un `~` inicial se expande; cualquier otro valor relativo se ignora). Desde la 0.9.1, el primer comando que supera su gate copia, una sola vez, el estado que drupilot 0.9.0 dejara en el directorio de datos del plugin de Claude Code (los originales se conservan). |
| `DRUPILOT_PATTERNS_FILE` | _(vacío)_ | El catálogo de patrones aprendidos. Vacío significa `<raíz>/.drupilot/patterns.json` (sin raíz de Drupal, `<repositorio>/.drupilot/patterns.json` en el nivel superior de git); un módulo portado por `/drupilot-layers` usa el catálogo del conjunto. Una ruta relativa se toma desde la raíz de Drupal, para que un equipo pueda compartir un fichero versionado. |
| `DRUPILOT_DDEV_CREATE_TIMEOUT` | `900` | Segundos que `/drupilot-setup` deja correr `ddev composer create-project` (y `ddev composer install`, cuando falta `vendor/`) antes de pararlo con un error claro (`0` = sin límite). Necesita `timeout` (o `gtimeout` en macOS); sin él el paso no tiene límite. |
| `DRUPILOT_CORE_CACHE` | `auto` | El core base cacheado de `/drupilot-setup` (ver [Core base cacheado](#core-base-cacheado)): `auto` reutiliza el árbol de la versión de core que congeló el lockfile o, si aún no hay ninguna congelada, el árbol más reciente construido para el mismo `DRUPILOT_DRUPAL_TARGET` dentro de `DRUPILOT_CORE_CACHE_MAX_AGE_DAYS` (el lock congela entonces esa versión); `locked` solo la versión congelada; `off` nunca reutiliza ni guarda uno. `DRUPILOT_DETERMINISTIC=false` nunca reutiliza un árbol pero sí refresca la caché. |
| `DRUPILOT_CORE_CACHE_MAX_AGE_DAYS` | `7` | Antigüedad máxima del core base cacheado que reutiliza `auto` cuando aún no hay versión de core congelada (`0` = sin límite). |
| `DRUPILOT_CORE_CACHE_KEEP` | `3` | Cores base cacheados que se conservan (los más recientes); `/drupilot-clean --core-cache` los borra todos. |
| `DRUPILOT_CODER_CONSTRAINT` | `^8.3` | Rama de `drupal/coder` (PHPCS 3.x vs 4.x). Solo se aplica en una resolución nueva (`DRUPILOT_TOOLCHAIN_SOURCE=range` o `DRUPILOT_DETERMINISTIC=false`); si no, se instala la versión del lock o la versión de referencia verificada (`config/toolchain-reference.json`). |
| `DRUPILOT_PHPSTAN_LEVEL` | `2` | Nivel base de PHPStan (detección de deprecaciones). |
| `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` | `6` | Nivel de PHPStan usado en la fase de refactor. |
| `DRUPILOT_VIABILITY_THRESHOLD` | `medium` | Umbral para el aviso de "refactor grande": `small`, `medium`, `large` o `xl` (≡ el veredicto S / M / L / XL). El aviso aparece cuando el veredicto lo supera estrictamente (con `medium`: L o XL). |
| `DRUPILOT_CONTRIB_MODE` | `semi` | `semi` (confirma acciones externas) o `auto`. |
| `DRUPILOT_ISSUE_TITLE` | `Drupal 11 compatibility` | Título por defecto del issue generado en Drupal.org. |
| `DRUPILOT_ISSUE_CATEGORY` | `Task` | Category por defecto del issue, tal como la nombra el formulario de Drupal.org (`Bug report` / `Task` / `Feature request` / `Support request` / `Plan`). El valor se copia tal cual en los campos del issue generados. |
| `DRUPILOT_ISSUE_PRIORITY` | `Normal` | Priority por defecto del issue, tal como la nombra el formulario de Drupal.org (`Critical` / `Major` / `Normal` / `Minor`). El valor se copia tal cual en los campos del issue generados. |
| `DRUPILOT_ISSUE_COMPONENT` | `Code` | Component por defecto del issue. La lista es **específica de cada proyecto** — verifícalo contra los componentes propios del proyecto. |
| `DRUPILOT_ISSUE_ASSIGNEE` | `self` | `self` (asignar a la cuenta que abre el issue) o `unassigned`. |
| `DRUPILOT_USE_DIGESTS_RULES` | `true` | Usar la capa complementaria `drupal-digests` tras el Rector oficial. |
| `DRUPILOT_DIGESTS_REF` | `main` | Commit/tag del repo `drupal-digests`, para reproducibilidad. |
| `DRUPILOT_GENERATE_RULES` | `ask` | Generar reglas Rector ad-hoc para deprecaciones no cubiertas: `ask` / `auto` / `off`. |
| `DRUPILOT_SOFT_DEPRECATIONS` | `report` | Qué hace la Fase 1 con las deprecaciones *blandas* — eliminadas solo en una major posterior de Drupal, así que siguen funcionando en todos los cores de Drupal 11 (p. ej. `user_load_by_name()`, `text_summary()`, `check_markup()`: deprecadas en 11.4.0, eliminadas en 13.0.0): `report` (las lista en los informes de viabilidad y de port — símbolo, deprecada en, eliminada en, esfuerzo — sin tocar el código), `defer` (las lista en *aplazado a la Fase 2*) o `fix` (las corrige cuando el reemplazo existe en el suelo de core declarado, mediante `DeprecationHelper::backwardsCompatibleCall()` cuando solo existe en cores más nuevos, y si no las aplaza). Las deprecaciones *duras* (eliminadas en una major ≤ la objetivo, p. ej. `user_roles()`) se corrigen siempre y son las únicas que cuentan en el veredicto de esfuerzo; la Fase 2 elimina también las blandas. |
| `DRUPILOT_ATTRIBUTES_MODE` | `keep` | Modo de la pasada de anotaciones → atributos (`convert-attributes.sh`): `keep` (añade el atributo y conserva la anotación: compatible con cores anteriores) o `strip` (elimina la anotación, solo en los tipos que soporta el suelo de core declarado salvo con `--raise-floor`). La Fase 1 usa siempre `keep`; la Fase 2 usa `strip` con un objetivo de core `^11` y `keep` mientras se mantenga deliberadamente `^10 || ^11`; esto fija el valor por defecto del script. Ver [Anotaciones de plugins a atributos PHP 8](#anotaciones-de-plugins-a-atributos-php-8). |
| `DRUPILOT_ATTRIBUTE_PLUGIN_TYPES` | _(vacío)_ | Tipos de plugin del proyecto o de contrib para la pasada de atributos, separados por comas: `Annotation=Fully\Qualified\AttributeClass[@MAJOR.MINOR]` (p. ej. `ExtraFieldDisplay=Drupal\extra_field\Attribute\ExtraFieldDisplay`). Un tipo solo se convierte si su clase de atributo existe bajo la raíz de Drupal, y su anotación solo se elimina si algún gestor de plugins referencia la clase. |
| `DRUPILOT_VERIFY_CORES` | `auto` | Qué cores comprueba estáticamente `verify-core-matrix.sh` (PHPStan + `php -l`): `auto` (las patas que declara `core_version_requirement`, una versión mayor inferior también en su suelo — `^10 \|\| ^11` → 10.0, la última 10.x y 11, `^10.3 \|\| ^11` → 10.3 y 11, `^11` → nada más), `off` (se omite; la mitad Drupal 10 sigue *declared-not-verified*) o una lista explícita como `10,11` o `10.3,11`. Los cores de referencia se guardan en caché en `<drupal_root>/.drupilot/cores/` y su versión exacta se congela en el lockfile. Ver [Verificar la mitad Drupal 10](#verificar-la-mitad-drupal-10). |
| `DRUPILOT_WANT_REFACTOR` | `false` | Si optaste por el refactor de Fase 2 para la recomendación del siguiente paso (`next-step.sh`, que usan `/drupilot` y `/drupilot-status`): `true` recomienda `/drupilot-refactor` justo después del port, antes de los tests, hasta que el módulo esté refactorizado; `false` deja el refactor como opt-in y recomienda los tests. Solo cambia la recomendación, nunca ejecuta nada. |
| `DRUPILOT_STATE_FORCE` | `false` | La etapa que ha alcanzado un port (`state.json` en el directorio de estado de drupilot: setup < assessed < ported < refactored < tested < contributed; la registran `port-report.sh`, una ejecución de toda la suite con `run-phpunit.sh` cuya preservación es `verified` o `verified-partial`, y `state.sh record`; ver [Estado por módulo](#estado-por-módulo)) nunca baja, así que volver a ejecutar `/drupilot-port` tras un refactor no la deshace. `true` permite que un nuevo registro la baje, p. ej. para reiniciar un port desde cero. |
| `DRUPILOT_AUTONOMOUS` | `false` | Modo manos fuera (equivale a la palabra de modo `auto`): setup→assess→port→refactor→test sin intervención, escribe el parche local, **nunca** contribuye. Ver [Modo autónomo](#modo-autónomo-manos-fuera). |
| `DRUPILOT_DETERMINISTIC` | `true` | Reproducibilidad (activado por defecto): congela el Drupal core, el toolchain de desarrollo, el SHA de digests y los add-ons de DDEV resueltos en un `drupilot-lock.json` por proyecto y los reutiliza en ejecuciones posteriores. Ponlo a `false` para resolver todo de nuevo cada vez y refrescar el lock. Ver [Determinismo](#determinismo-reproducible-por-defecto). |
| `DRUPILOT_TOOLCHAIN_SOURCE` | `auto` | De dónde toma `install-toolchain.sh` las versiones del toolchain de desarrollo: `auto` (el lock del proyecto cuando fija el conjunto verificado completo; si no, la referencia verificada que trae el plugin, `config/toolchain-reference.json`; los rangos de `.packages` cuando `DRUPILOT_DETERMINISTIC=false`), `reference` (siempre el conjunto verificado — la vía de reparación) o `range` (resolución nueva). |
| `DRUPILOT_POST_EDIT_LINT` | `autofix` | El lint incremental de PostToolUse: `autofix` (ejecuta phpcbf + phpcs, y **avisa** cuando modifica un fichero), `report` (solo phpcs, nunca edita ficheros) u `off`. Es consciente de fase — en la Fase 1 saca solo **errores** de compatibilidad, dejando los warnings de estilo para el refactor, y su phpcbf no toca los `use` sin usar (si no, borraría un `use` añadido una edición antes del código que lo necesita; el bucle de validación los limpia). Usa el mismo ruleset que `run-phpcs.sh` resolvió por última vez para la extensión (ver `DRUPILOT_PHPCS_RULESET`). |
| `DRUPILOT_PHPCS_RULESET` | `auto` | Qué ruleset de PHPCS usa `run-phpcs.sh`: `auto` (el **propio** `.phpcs.xml` / `phpcs.xml` / `.phpcs.xml.dist` / `phpcs.xml.dist` del sujeto, buscado desde el sujeto hasta la raíz de Drupal, su raíz de git y el checkout de origen de una colocación por copia — el `phpcs.xml.dist` que genera drupilot nunca cuenta —, y si no hay, `Drupal,DrupalPractice`), `drupilot` (siempre `Drupal,DrupalPractice`, el comportamiento de drupilot 0.8.4 y versiones publicadas anteriores) o la ruta de un fichero de ruleset. Un ruleset del proyecto que PHPCS no puede cargar (p. ej. referencia PHPCompatibility, no instalado en el banco de pruebas) cae a `Drupal,DrupalPractice` con un aviso; la ruta explícita de un ruleset que no se puede cargar es un error (salida 2), nunca un cambio silencioso al estándar por defecto. `run-phpcs.sh --json` y `port-report.md` dicen cuál se usó. |
| `DRUPILOT_PHPCS_TEST_VERSION` | _(vacío)_ | El `testVersion` de PHPCompatibility que se pasa en cada ejecución de `run-phpcs.sh` con `--runtime-set` (p. ej. `8.1-`). Vacío = `<DRUPILOT_PHP_TARGET>-`, salvo que nunca se sobrescribe un `<config name="testVersion">` propio del ruleset y que un testVersion declarado como `<property>` dentro de un `<rule>` se pasa tal cual. |
| `DRUPILOT_HOOKS_GUARD` | `ask` | `ask`: el hook `guard-contrib` pregunta antes de un `git commit` que se salta los git hooks del repositorio (`--no-verify`, `-n`, `git -c core.hooksPath=…`) cuando hay de verdad un hook pre-commit/commit-msg instalado — en todos los modos de contribución y en modo autónomo. `off` desactiva esa comprobación. Nunca deniega y no cambia la protección de push/MR. |
| `DRUPILOT_SESSION_CONTEXT` | `on` | Interruptor `on`/`off` del resumen de entorno de SessionStart. |
| `DRUPILOT_REFACTOR_SCOPE` | _(se pregunta)_ | Conjunto persistido de modernizaciones de Fase 2 a aplicar, un subconjunto separado por comas de `attributes`, `di`, `strict-types`, `final`, `deprecations`. Normalmente se elige con el multi-select de `/drupilot-refactor` y se recuerda en `.drupilot.json`. |
| `DRUPILOT_CHOICE_<KEY>` | _(sin definir)_ | Pre-responde una elección en pestaña, para que no se pregunte. Las claves y sus valores están en [Pre-responder elecciones en pestañas](#pre-responder-elecciones-en-pestañas). |

Otras variables de entorno útiles: `DRUPILOT_GITLAB_PAT` (tu Personal Access Token de GitLab, leído solo en runtime, nunca persistido), `DRUPILOT_ASSUME_YES=1` (responder sí a las confirmaciones sí/no de los scripts, haya o no terminal, y tomar el valor por defecto de cada elección del lado de los scripts; el borrado de `/drupilot-clean` sigue necesitando `--yes` o una respuesta interactiva), `DRUPILOT_NONINTERACTIVE=1` (no preguntar nunca: cada pregunta toma su valor por defecto seguro; ver [Ejecutar bajo otra herramienta](#ejecutar-bajo-otra-herramienta-contrato-no-interactivo)), `NO_COLOR=1`.

Ejemplo — apuntar a PHP 8.4 y abandonar el soporte de Drupal 10 durante una sesión:

```bash
export DRUPILOT_PHP_TARGET=8.4
export DRUPILOT_CORE_TARGET_STRATEGY=d11-only   # solo ^11 (abandona Drupal 10)
```

### Pre-responder elecciones en pestañas

Cada bifurcación de peso es una pestaña con la recomendación preseleccionada. Define `DRUPILOT_CHOICE_<KEY>` (una variable de entorno, o una clave en `.drupilot.json`) para responder una de antemano. El comando omite entonces esa pestaña, indica en una línea qué variable la respondió y aplica el valor exactamente como la respuesta de la pestaña: cuando la respuesta de la pestaña se recuerda, la pre-respuesta se guarda en `.drupilot.json` del mismo modo. Una pre-respuesta también se aplica en una ejecución autónoma. Un valor fuera del conjunto permitido se ignora con un aviso y la pestaña se muestra como siempre (una ejecución autónoma toma su valor seguro por defecto). Un argumento explícito del comando gana sobre ella (`/drupilot-setup --php`, `/drupilot-clean --level`, una palabra de modo de `/drupilot`), y también una variable de entorno del propio ajuste recordado (p. ej. `DRUPILOT_PHP_TARGET`).

| Clave (`DRUPILOT_CHOICE_…`) | Comando — pestaña | Valores permitidos | Se recuerda como |
| --- | --- | --- | --- |
| `INTENT` | `/drupilot` — Cómo continuar (solo cuando la petición es ambigua) | `full`, `next`, `auto` | — |
| `PHP_TARGET` | `/drupilot-setup` — Target de PHP | `8.3`, `8.4`, `8.5` (requiere Drupal 11.3 o posterior: se acepta, con un aviso si el core es más antiguo) | `DRUPILOT_PHP_TARGET` |
| `PLACEMENT` | `/drupilot-setup` — Disposición del workspace | `move`, `symlink`, `copy` | `DRUPILOT_PLACEMENT` |
| `CONFIG_CONFLICT` | `/drupilot-setup` — un `rector.php` / `phpstan.neon` / `phpcs.xml.dist` editado a mano | `keep`, `replace` (se guarda una copia de la versión anterior) | — |
| `EXISTING_WORK` | `/drupilot-assess` — Trabajo existente | `independent`, `existing` | — |
| `CORE_TARGET` | `/drupilot-port` — Target de core | `auto`, `keep-d10`, `d11-only` | `DRUPILOT_CORE_TARGET_STRATEGY` |
| `DIGESTS_RULES` | `/drupilot-port` — Reglas digests | `apply-unflagged`, `skip` (la revisión regla a regla solo es interactiva) | — |
| `PORT_ATTRIBUTES` | `/drupilot-port` — Atributos de plugins | `skip`, `add` | — |
| `D10_CHECK` | `/drupilot-port` — Comprobación de Drupal 10 (solo cuando falla) | `fix`, `raise-floor`, `d11-only`, `declared` | `d11-only` como `DRUPILOT_CORE_TARGET_STRATEGY` |
| `LEARN` | `/drupilot-port`, `/drupilot-refactor` — Aprender | `all`, `none` | — |
| `NEXT_STEP` | `/drupilot-port`, `/drupilot-refactor` — Siguiente paso | `test`, `patch`, `refactor` (solo tras un port), `done` | — |
| `REFACTOR_SCOPE` | `/drupilot-refactor` — Modernizar | un subconjunto separado por comas de `attributes`, `di`, `strict-types`, `final`, `deprecations` | `DRUPILOT_REFACTOR_SCOPE` |
| `PHPSTAN_LEVEL` | `/drupilot-refactor` — Nivel de PHPStan | `6`, `5`, `4` | `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` |
| `ATTRIBUTE_FLOOR` | `/drupilot-refactor` — Suelo de atributos | `keep`, `raise-floor` | — |
| `PATCH_KIND` | `/drupilot-patch` — Parche para | `local`, `issue` (el id del issue sigue haciendo falta) | — |
| `CONTRIB_MODE` | `/drupilot-contribute` — Modo de contribución | `semi`, `auto` | `DRUPILOT_CONTRIB_MODE` |
| `CLEAN_LEVEL` | `/drupilot-clean` — Nivel de limpieza | `vendor`, `ddev`, `workspace` | — |
| `LAYERS_PLAN` | `/drupilot-layers` — Plan de capas | `port`, `stop` | — |
| `LAYERS_SANDBOX` | `/drupilot-layers` — Sandbox de capas | `per-module`, `shared` | `DRUPILOT_LAYERS_SANDBOX` |
| `LAYERS_CONFIRM` | `/drupilot-layers` — Portar esta capa | `proceed`, `stop` | — |
| `LAYERS_NEXT` | `/drupilot-layers` — Siguiente capa | `next-layer`, `stop` | — |

Algunas bifurcaciones nunca se pre-responden, porque deben seguir siendo una decisión humana: el push a Drupal.org (`PUSH`; `DRUPILOT_CONTRIB_MODE=auto` es el ajuste explícito que lo omite), la confirmación de la limpieza (`CLEAN_CONFIRM`; los cores base cacheados solo se borran con `--core-cache`), lo que instala `/drupilot-doctor` (`DOCTOR_INSTALL`), añadir las dependencias propuestas a los ficheros `info.yml` en `/drupilot-layers`, y las opciones hacia el exterior de la pestaña «Siguiente paso» (contribuir, parche de comentario de issue). Sus variables no tienen efecto.

El registro está en `config/choices.json`. `scripts/env/choice.sh --list` lo imprime, y `scripts/env/choice.sh --key KEY --subject DIR --json` muestra cómo se resuelve un valor (`value` es `null` cuando la pestaña se va a preguntar). Las preguntas del lado de los scripts usan las mismas variables: `choose_one KEY …` de `scripts/lib/common.sh` (el respaldo en shell de una pestaña) devuelve un `DRUPILOT_CHOICE_<KEY>` válido sin preguntar, e ignora uno no válido con un aviso.

```bash
# Port desatendido que conserva Drupal 10, omite la capa digests y no añade atributos:
export DRUPILOT_CHOICE_CORE_TARGET=keep-d10
export DRUPILOT_CHOICE_DIGESTS_RULES=skip
export DRUPILOT_CHOICE_PORT_ATTRIBUTES=skip
```

---

## Determinismo (reproducible por defecto)

Portar el mismo módulo dos veces debería dar el mismo resultado. drupilot es **determinista por defecto** (`DRUPILOT_DETERMINISTIC=true`): la primera vez que resuelve las partes móviles de un port las **congela** en un `drupilot-lock.json` por proyecto (guardado en el directorio de estado de drupilot, no en tu árbol de proyecto) y las **reutiliza** en ejecuciones posteriores:

- la versión exacta de **Drupal core** y las versiones del **toolchain de desarrollo** (`drupal-rector` y su motor `rector/rector`, PHPStan + extensiones, `coder`/PHPCS, Drush, `drupal/core-dev`) leídas del `composer.lock` generado;
- el **commit (SHA) de digests** al que resolvió la rama `main` — así la capa de reglas generadas por IA queda fija para el proyecto aunque su ref por defecto siga siendo `main`;
- las versiones de los **add-ons de DDEV** instalados;
- el **core de Drupal de referencia** exacto con el que se construyó cada pata de la matriz de cores (`.verify_cores`, p. ej. Drupal 10.6.18 para la pata `10`), para que `verify-core-matrix.sh` siga juzgando contra el mismo core.

El lock también indica qué drupilot lo escribió por última vez: `drupilot_version` (la versión de `plugin.json`, que se actualiza en cada escritura del lock) y, cuando drupilot se ejecuta desde un checkout de git, como una rama de desarrollo que aún lleva la última versión publicada, `drupilot_revision` (`git describe`, p. ej. `v0.8.3-45-gb97266d`).

Funciona como un `composer.lock`: los rangos de versión en `config/defaults.json` siguen siendo flexibles, pero el lock fija exactamente lo que se usó. Eso incluye reconstruir un banco de pruebas eliminado: cuando `ddev-up.sh` tiene que volver a crear el proyecto (p. ej. tras `/drupilot-clean --level workspace`), pide `drupal/recommended-project:<versión de core congelada>` en lugar del `DRUPILOT_DRUPAL_TARGET` flotante. `scripts/env/lock-sync.sh` lo captura/actualiza (`ddev-up.sh`, `ddev-add-ons.sh` e `install-toolchain.sh` lo llaman automáticamente).

**Conjunto de referencia verificado.** Un proyecto que aún no tiene lock no resuelve de nuevo los rangos del toolchain: `scripts/env/install-toolchain.sh` instala la **matriz verificada** que trae el plugin, `config/toolchain-reference.json` — versiones exactas de `drupal-rector`, `rector/rector`, PHPStan + extensiones, `coder`, Drush y `upgrade_status` verificadas juntas de principio a fin. Así, un banco de pruebas nuevo creado después de una release rota aguas arriba (por ejemplo `rector/rector` 2.6.2+, que hace fallar a `drupal-rector` 0.21) sigue recibiendo un conjunto que funciona. Cada instalación termina con un **smoke test** (un dry-run de Rector con el set de Drupal 10 más `phpstan --version`) y sale con código 3, mostrando las versiones instaladas frente a las verificadas, cuando el toolchain está roto.

**Vía de escape:** pon `DRUPILOT_DETERMINISTIC=false` para ignorar el lock, resolver todo de nuevo (lo más reciente de cada rango, el `main` vivo para digests) y refrescar el lock. `lock-sync.sh --refresh` hace lo mismo solo para el SHA de digests.

Más allá de las versiones, drupilot también hace que el *proceso* sea objetivo: orden de ficheros estable, un baremo numérico S/M/L/XL, greps fijos para las rupturas duras, y un criterio de "hecho" juzgado únicamente por Rector/PHPStan/PHPCS + la suite de tests.

---

## Casos de uso

### 1. "¿Merece la pena portar este módulo?" — solo evaluación

```text
/drupilot-assess web/modules/custom/my_module
```

Obtienes un informe markdown (cacheado para más tarde) que clasifica cada hallazgo como autocorregible (Rector) o manual, lista las rupturas duras, el estado del `info.yml` y el soporte D11 de las dependencias contrib, y un veredicto **S/M/L/XL** con un plan por etapas. No se modifica nada.

### 2. Portabilidad guiada de principio a fin de un módulo custom

```text
/drupilot web/modules/custom/my_module full
```

O pídelo sin más en lenguaje natural: «porta web/modules/custom/my_module a Drupal 11». En ambos casos el router expone su plan y pide tu confirmación antes de empezar; después comprueba tu entorno, ejecuta el assess, aplica la portabilidad de Fase 1, ejecuta la suite de tests en DDEV y reporta en cada paso, preguntando de nuevo en cada elección de peso. Un `/drupilot web/modules/custom/my_module` a secas (sin palabra de modo) no ejecuta el flujo: solo resume el estado y recomienda el siguiente paso (salvo que esté activo `DRUPILOT_AUTONOMOUS=true`, que lo ejecuta sin intervención). Al terminar la portabilidad escribe un `MODULE-port-to-drupal-11.patch` local para que puedas revisar o probar el cambio de inmediato.

Para que los agentes lo hagan todo sin pausas, añade `auto` (ver [Modo autónomo](#modo-autónomo-manos-fuera)):

```text
/drupilot web/modules/custom/my_module auto
```

### 3. Solo portabilidad mínima (Fase 1), sin refactor

```text
/drupilot-setup web/modules/custom/my_module
/drupilot-assess web/modules/custom/my_module
/drupilot-port web/modules/custom/my_module
/drupilot-test web/modules/custom/my_module
```

La funcionalidad permanece idéntica; el módulo queda compatible con D11 sin deprecaciones bloqueantes. Ideal cuando quieres el diff más pequeño y seguro.

### 4. Modernizar al "estilo Drupal 11" (Fase 2)

```text
/drupilot-refactor web/modules/custom/my_module
```

Convierte anotaciones a atributos PHP 8 (con la pasada determinista `convert-attributes.sh`), introduce inyección de dependencias y tipados estrictos, elimina toda deprecación, sube PHPStan a nivel 5–6 y mantiene la suite en verde. Cada cambio significativo se explica.

### 5. Ejecutar la suite de tests completa en DDEV

```text
/drupilot-test web/modules/custom/my_module
```

Ejecuta Unit, Kernel, Functional y FunctionalJavascript (Selenium) dentro de DDEV y reporta cobertura; el comando no admite ningún otro argumento. Para ejecutar un solo grupo, o sin cobertura, llama directamente al script:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/tests/run-phpunit.sh" --subject web/modules/custom/my_module --type kernel
bash "$CLAUDE_PLUGIN_ROOT/scripts/tests/run-phpunit.sh" --subject web/modules/custom/my_module --type all --coverage
```

Si un test no puede pasar por una causa externa (p. ej. una dependencia contrib sin soporte D11), se documenta explícitamente en vez de silenciarlo.

Para demostrar que un test nuevo protege el cambio para el que se escribió (un control negativo):

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/tests/negative-control.sh" --subject web/modules/custom/my_module \
  --type kernel --filter testQueueWorker --revert-to HEAD --path src/Plugin/QueueWorker/MyWorker.php --json
```

Código de salida `0` eficaz (rojo con el cambio deshecho, verde al restaurar) · `4` ineficaz · `1` no concluyente o error de uso · `2` entorno bloqueado.

### 6. Obtén el parche — prueba en local ahora, contribuye después

```text
/drupilot-patch web/modules/custom/my_module
```

Escribe `MODULE-port-to-drupal-11.patch` junto al módulo — offline, sin push, sin cuenta de Drupal.org. Aplícalo en otra copia con `git apply`. El parche se calcula contra el **punto de bifurcación** de tu rama — su upstream si lo tiene; si no, el más cercano entre `origin/HEAD`, las demás ramas remotas y la etiqueta más próxima (p. ej. una rama local creada desde una etiqueta de release) — así que contiene exactamente el port, esté confirmado o no. Para calcularlo contra otra referencia, ejecuta directamente el script: `bash "$CLAUDE_PLUGIN_ROOT/scripts/contrib/make-patch.sh" --local --subject web/modules/custom/my_module --base <ref>`. Se mantiene fuera de `git status` mediante el `.git/info/exclude` local del repo. ¿Quieres adjuntarlo a un issue y validarlo allí antes de abrir un Merge Request? Pasa el id del issue y elige **Drupal.org issue comment** en la pestaña «Patch for» (Parche para; la opción por defecto de la pestaña es el parche local normal; `DRUPILOT_CHOICE_PATCH_KIND=issue` la responde de antemano). El id del issue y el número de comentario (por defecto `1`) dan entonces nombre al fichero `MODULE-port-to-drupal-11-ISSUE-COMMENT.patch`, y con él se genera un comentario listo para pegar:

```text
/drupilot-patch web/modules/custom/my_module 3456789
```

Esto está totalmente **desacoplado de contribuir**: el Merge Request upstream (que hace rebase y verifica en duro que el parche aplica sobre `origin/BASE`) sigue siendo un paso aparte y opt-in que ejecutas con `/drupilot-contribute` cuando estés listo.

### 7. Portar por capas los módulos custom de un monorepo

```text
/drupilot-layers web/modules/custom
/drupilot-layers web/modules/custom run --layer 0
/drupilot-layers web/modules/custom plan --edges declared   # solo por las dependencias declaradas
```

La primera llamada es de solo lectura. Imprime y guarda `.drupilot/layers.md`, que contiene tres cosas:
- las capas (porta primero la capa 0; una capa solo depende de las anteriores);
- los ciclos (sus módulos se portan juntos);
- cada dependencia no declarada, con su evidencia (`fichero:línea`, clase / servicio / ruta / librería / plugin) y la entrada que hay que añadir: `- acme_core:acme_core` para un módulo del conjunto, `- drupal:node` para core, `- pathauto:pathauto` para contrib (comprueba el nombre del proyecto).

Un módulo que solo declara parte de lo que usa aparece donde de verdad le corresponde, con una nota de que con solo sus dependencias declaradas se portaría demasiado pronto. Las entradas propuestas nunca se aplican sin tu confirmación.

`run` porta una capa, un módulo cada vez, con el flujo habitual setup → assess → port → test, y escribe `.drupilot/layer-N-report.md` a partir de una única plantilla (`templates/layer-report.md.tmpl`), así que todas las capas tienen las mismas secciones:
1. resultado por módulo: etapa, esfuerzo, veredictos de preservación y de Drupal 10, higiene previa, dependencias no declaradas, ficheros de Rector, cambios de Rector revertidos, arreglos post-port, parche y un enlace al informe de port del módulo;
2. reglas de Rector frecuentes, con sus aciertos (ficheros cambiados) **y** cuántas veces se revirtió cada una;
3. cambios manuales;
4. arreglos post-port;
5. bugs previos (no corregidos);
6. cambios de comportamiento a revisar en el PR;
7. desviaciones de tooling y de flujo;
8. cómo se validó.

Las secciones 2-8 salen del manifiesto del port y del registro de decisiones de cada módulo, así que una regla revertida en varios módulos salta a la vista. `--json` añade el `aggregate` entre módulos.

Todo el conjunto comparte un único [catálogo de patrones aprendidos](#patrones-aprendidos). Cada módulo se analiza con él antes de portarlo, y lo que enseña su port se registra ahí, así que las capas posteriores se comprueban contra los fallos que sufrieron las anteriores.

Una regresión detiene la siguiente capa. Los scripts también funcionan por separado:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/analysis/layers.sh" --dir web/modules/custom --json           # capas, ciclos, dependencias no declaradas
bash "$CLAUDE_PLUGIN_ROOT/scripts/analysis/lint-extension-metadata.sh" --subject web/modules/custom/acme_api --json
bash "$CLAUDE_PLUGIN_ROOT/scripts/analysis/layer-report.sh" --dir web/modules/custom --layer 1  # informe consolidado
bash "$CLAUDE_PLUGIN_ROOT/scripts/analysis/patterns.sh" scan --subject web/modules/custom/acme_invoice  # fallos que aprendieron las capas anteriores
bash "$CLAUDE_PLUGIN_ROOT/scripts/analysis/layer-report.sh" --subject ../a-d11/web/modules/custom/a --subject ../b-d11/web/modules/custom/b --name "lote 1"  # cualquier conjunto de módulos
```

### 8. Contribuir el arreglo de vuelta a Drupal.org

Semiautomático (recomendado — confirma cada push / MR):

```text
/drupilot-contribute web/modules/contrib/some_module 3456789
```

Totalmente automático (requiere SSH o un PAT configurado):

```bash
export DRUPILOT_CONTRIB_MODE=auto
export DRUPILOT_GITLAB_PAT=glpat-xxxxxxxx   # nunca se almacena; se lee en runtime
```
```text
/drupilot-contribute web/modules/contrib/some_module 3456789
```

Cuando el issue aún no existe, genera el **resumen del issue** (la plantilla estándar de Drupal.org — para un port que preserva el comportamiento, solo las secciones que aplican: Problem/Motivation, Proposed resolution, Remaining tasks) y los **valores recomendados de los campos** (Title, Category `Task`, Priority `Normal`, Version derivada de la rama base, Component `Code`, Assigned a ti), ya que el issue solo puede crearse en la web. Después crea el issue fork, la rama y el commit (en el formato correcto, detectando la convención del proyecto), hace push, abre el Merge Request — con un breve **comentario** generado como descripción — vía la API de GitLab, **degradando con gracia** a una URL de MR de un clic si la API está bloqueada. **Siempre escribe un `.patch`** (`MODULE-port-to-drupal-11-ISSUEID-COMMENT.patch`) y **verifica que aplica limpio** sobre la versión a la que se refiere (descartando un parche que no aplica, para que nunca entregues uno roto) para adjuntarlo al issue junto al MR y el comentario. Te recuerda que **el crédito lo asignan los maintainers** mediante el Contribution Record del issue, y nunca expone tu PAT.

---

## Cómo funciona (arquitectura)

- **Comandos** (`commands/*.md`) son los puntos de entrada. Cada uno valida sus propios requisitos vía el motor de preflight antes de hacer nada.
- **Skills** (`skills/*/SKILL.md`) llevan el conocimiento operativo reutilizable (entorno DDEV, estudio de viabilidad, portabilidad mínima, refactor completo, adaptación de tests, ajuste del target de PHP, contribución a Drupal).
- **Subagentes** (`agents/*.md`) son los especialistas a los que delegan los comandos: `drupal-port-orchestrator`, `drupal-viability-analyst`, `drupal-test-engineer`, `drupal-contrib-publisher`.
- **Hooks** (`hooks/hooks.json`):
  - `SessionStart` → un detector de entorno ligero que resume tu target de PHP y la disponibilidad (siléncialo con `DRUPILOT_SESSION_CONTEXT=off`).
  - `PostToolUse` (Write|Edit) → `phpcbf` + `phpcs` incremental sobre los ficheros Drupal editados; **consciente de fase** (la Fase 1 saca solo errores de compatibilidad) y controlable con `DRUPILOT_POST_EDIT_LINT` (`autofix`/`report`/`off`), y te avisa cuando modifica un fichero.
  - `PreToolUse` (Bash) → pide confirmación antes de cualquier `git push` / acción de MR hacia el exterior en modo `semi`, y **siempre** en una ejecución autónoma (que nunca debe empujar por su cuenta) o con `DRUPILOT_NONINTERACTIVE=1`; también pregunta antes de un `git commit` que se salta los git hooks activos del repositorio (`DRUPILOT_HOOKS_GUARD`).
- **Scripts** (`scripts/`) son una librería de shell robusta e idempotente: las librerías compartidas de `lib/` (`common.sh`, `ext-scan.sh`, `php-scan.sh`), el motor de requisitos `env/preflight.sh`, el registro de estado por módulo `env/state.sh`, y los wrappers de `analysis/`, `tests/` y `contrib/` que invocan las skills y los comandos.
- **Plantillas** (`templates/`) son configuraciones parametrizadas (`rector.php`, `phpstan.neon`, `phpcs.xml.dist`, config de DDEV + entorno de tests, plantillas de informe) afinadas por el target de PHP.

Consulta **[FLOW_es.md](FLOW_es.md)** para un diagrama visual de todo el flujo — qué herramienta actúa en cada paso, dónde interviene la IA y las dos fases de la portabilidad.

### Referencia de scripts

Todos los scripts ejecutables viven en `scripts/` (o en `hooks/scripts/` los hooks) y cargan `scripts/lib/common.sh`. Los de `scripts/` muestran la ayuda `-h` desde su cabecera, dejan su salida parseable en STDOUT (`--json` cuando un comando la lee) y registran en STDERR; los hooks no admiten opciones, leen JSON por stdin y siempre terminan con código 0. Los ficheros de `lib/` son librerías que los scripts cargan con `source`; no se ejecutan por sí solos. Los comandos y las skills los llaman por ti; también puedes ejecutarlos tú con `CLAUDE_PLUGIN_ROOT` definido. Los códigos de salida siguen una convención (la cabecera de cada script da el significado exacto):

| Código | Significado |
| --- | --- |
| `0` | Hecho: bien, nada bloqueante, o un resultado solo informativo (los hallazgos que son datos, como los ciclos de `layers.sh` o los hallazgos de `lint-extension-metadata.sh`, nunca fallan). |
| `1` | Error de uso o interno. Algunos scripts también lo usan para un resultado negativo: `run-phpstan.sh` (PHPStan informó de hallazgos), `negative-control.sh` (un control no concluyente), `check.sh` / `smoke.sh` (falló un gate o una prueba), `ddev-add-ons.sh` (falló un add-on obligatorio), `install-deps.sh` (falló una instalación), `place-subject.sh` (colocación rechazada), `make-patch.sh` (un parche de contribución que choca al hacer rebase o no se aplica sobre su base se descarta) y `run-phpunit.sh --baseline` (no se ejecutó ningún test, así que no se registró ninguna línea base). `run-phpcs.sh` y `run-upgrade-status.sh` devuelven el código propio de la herramienta (PHPCS / Drush; en PHPCS, distinto de cero significa infracciones o un error de PHPCS). |
| `2` | Falló un gate de requisitos: una herramienta ausente o demasiado antigua, Docker o DDEV parados, sin raíz de Drupal ni banco de pruebas, PHPUnit (`drupal/core-dev`) sin instalar. |
| `3` | Un resultado bloqueante: hallazgos de error (`check-port-safety.sh`, `scan-signature-changes.sh`), un grupo de tests fallido (`run-phpunit.sh`), una pata de la matriz de cores fallida, un fallo sin veredicto (`run-phpstan.sh`, la pasada oficial de `run-rector.sh`, `convert-attributes.sh`), un toolchain roto (`install-toolchain.sh`), una configuración que difiere o no supera la validación (`render-templates.sh`), una raíz rechazada (`clean.sh`), un push cancelado en la confirmación o fallido (`open-mr.sh`), un equivalente de hook fallido (`git-hooks.sh`), o `port-summary.sh --strict` sobre un port bloqueado. |
| `4` | Un resultado parcial o ineficaz: `run-rector.sh --digests` cuando solo falló la pasada de digests (el resultado oficial se mantiene), `negative-control.sh` cuando el test sigue en verde sin su cambio. |

`negative-control.sh` también sale con `130` / `143` si se interrumpe (Ctrl-C / SIGTERM), tras restaurar el código.

| Script | Qué hace |
| --- | --- |
| **`lib/`** | |
| `common.sh` | El contrato compartido que cargan todos los scripts: registro de mensajes, configuración y preferencias, el lockfile, `choose_one`, utilidades de sujeto y de rutas. |
| `ext-scan.sh` | El análisis compartido de dependencias de un conjunto de extensiones (capas, dependencias no declaradas), que cargan `layers.sh` y `lint-extension-metadata.sh`. |
| `php-scan.sh` | Las heurísticas compartidas de clases PHP (imports, métodos, ascendencia, parámetros del constructor), que cargan los scripts de port-safety, firmas, metadatos y atributos. |
| **`env/`** | |
| `preflight.sh` | El gate de requisitos (perfiles `analyze`/`setup`/`test`/`contribute`/`all`); `--extended` añade las comprobaciones de salud del doctor. |
| `install-deps.sh` | Instalación asistida según el SO de git, jq, PHP, Composer, Docker y DDEV (solo tras confirmar). |
| `detect-php.sh` | El target de PHP efectivo, y si drupilot lo soporta del todo (8.5 requiere Drupal 11.3 o posterior). |
| `resolve-workspace.sh` | Dónde va el banco de pruebas de un módulo suelto (solo lectura; `--workspace DIR`). |
| `ddev-up.sh` | Crea y arranca el proyecto DDEV de Drupal 11 (core base en caché, versión de core congelada). |
| `place-subject.sh` | Mueve, enlaza o copia un módulo suelto dentro del banco de pruebas. |
| `ddev-add-ons.sh` | Instala los add-ons `ddev-drupal-contrib` y Selenium. |
| `install-toolchain.sh` | Instala el toolchain de desarrollo verificado, lo prueba y lo congela en el lock. |
| `render-templates.sh` | Genera `rector.php`, `phpstan.neon`, `phpcs.xml.dist` y la config de testing de DDEV, validados, sin pisar una edición a mano. |
| `lock-sync.sh` | Captura el lockfile de reproducibilidad (`drupilot-lock.json`). |
| `ensure-gitignore.sh` | Mantiene los artefactos de drupilot fuera de git en la raíz de Drupal. |
| `origin-hygiene.sh` | Demuestra que el port dejó limpio tu checkout original (instantánea antes, comprobación después). |
| `state.sh` | El registro de estado por módulo (`record`, `refresh`, `show`, `list` para `/drupilot-status --all`). |
| `next-step.sh` | La fuente única de la escalera de "¿qué sigue?". |
| `choice.sh` | Resuelve y valida una pre-respuesta `DRUPILOT_CHOICE_<KEY>` contra `config/choices.json` (`--list` imprime el registro). |
| `clean.sh` | Libera el proyecto DDEV, los árboles de Composer o el workspace entero de un banco de pruebas (`/drupilot-clean`). |
| **`analysis/`** | |
| `core-strategy.sh` | Recomienda `^11` o `^10 \|\| ^11`, el `require.php` y el salto de versión. |
| `deps-status.sh` | Preparación para Drupal 11 de cada dependencia contrib (historial de releases de drupal.org). |
| `detect-php-floor.sh` | El PHP mínimo que necesita el código (heurístico). |
| `run-rector.sh` | drupal-rector oficial, la capa digests (`--digests`) y la pasada de atributos (`--attributes`), en simulación o aplicando. |
| `run-phpstan.sh` / `run-phpcs.sh` | PHPStan con phpstan-drupal + reglas de deprecación; PHPCS/phpcbf con el ruleset del proyecto o Drupal + DrupalPractice. |
| `run-upgrade-status.sh` | Upgrade Status sobre un sitio instalado. |
| `classify-deprecations.sh` | Separa las deprecaciones en duras y blandas (`DRUPILOT_SOFT_DEPRECATIONS`). |
| `explain-deprecations.sh` | Explica cada deprecación: qué cambió, el arreglo, un enlace a los change records; el mapa curado que lee es `config/deprecations.json`. |
| `check-port-safety.sh` | Comprobaciones deterministas de roturas que introducen los ports (interfaces de DI perdidas, closures en callbacks de Form API, ...); las comprobaciones y su severidad están en `config/port-checks.json`. |
| `scan-signature-changes.sh` | Colisiones con cambios de firma del core de Drupal 10 → 11 en el suelo declarado. |
| `verify-core-matrix.sh` | PHPStan + `php -l` en cada core que declara el módulo (la mitad Drupal 10 de `^10 \|\| ^11`). |
| `set-core-requirement.sh` | Escribe `core_version_requirement` en el `info.yml` principal y en el de cada submódulo. |
| `convert-attributes.sh` | Pasada opcional de anotaciones de plugin → atributos PHP 8. |
| `lint-extension-metadata.sh` | Higiene preexistente: config sin schema, rutas inexistentes, servicios huérfanos, dependencias no declaradas. |
| `layers.sh` / `layer-report.sh` | Capas de portabilidad de un conjunto de módulos; el informe consolidado por capa (`/drupilot-layers`). |
| `patterns.sh` | El catálogo del proyecto de fallos de port aprendidos (`scan`, `add`, `harvest`, ...). |
| `log-decision.sh` | El registro de decisiones: cada divergencia de la salida de una herramienta, con qué y por qué. |
| `port-report.sh` | El informe humano `port-report.md` (también refresca `port-summary.json`). |
| `port-summary.sh` | El resumen versionado para máquinas de un port, para wrappers (`--json`, `--strict`). |
| **`tests/`** | |
| `discover-tests.sh` | Encuentra y clasifica las clases de test PHPUnit. |
| `run-phpunit.sh` | Ejecuta la suite en DDEV y registra el veredicto de preservación (con una línea base previa al port). |
| `negative-control.sh` | Demuestra que un test nuevo falla sin el cambio que protege. |
| **`contrib/`** | |
| `make-patch.sh` | El parche local de vista previa (`--local`) o el parche de contribución verificado. |
| `make-issue.sh` | El resumen del issue de Drupal.org, los valores de los campos y el comentario del MR. |
| `find-upstream-issue.sh` | Busca un issue de Drupal 11 ya existente para el proyecto. |
| `check-prereqs.sh` / `setup-git.sh` | Requisitos de contribución; la identidad de git. |
| `issue-fork.sh` / `open-mr.sh` | El remoto y la rama del issue fork; push y Merge Request (confirmados antes). |
| `git-hooks.sh` | Detecta los git hooks del repositorio y ejecuta sus equivalentes cuando un hook no puede ejecutarse. |
| **`dev/`** | |
| `check.sh` | El gate de desarrollo del propio drupilot (ver [Desarrollo de drupilot](#desarrollo-de-drupilot)). |
| `smoke.sh` | Pruebas de humo sin Docker con resultados esperados sobre `tests/fixtures/` (el paso opcional `smoke` del gate). |
| **`hooks/scripts/`** | |
| `session-detect-env.sh` / `post-edit-lint.sh` / `guard-contrib.sh` | Los hooks SessionStart, PostToolUse y PreToolUse (ver [Qué es automático](#qué-es-automático-vs-dónde-decide-la-ia)). |

---

## La capa complementaria drupal-digests

`dbuytaert/drupal-digests` es un conjunto de reglas de Rector **experimental y generado por IA** (de Dries Buytaert) que cubre deprecaciones muy recientes que el `palantirnet/drupal-rector` oficial puede que aún no incluya. Es un **repositorio Git, no un paquete Composer, y no tiene licencia**, por lo que `drupilot`:

- **nunca lo vendoriza ni lo redistribuye** — se clona en una caché en runtime y se referencia por ruta (puedes fijar un ref con `DRUPILOT_DIGESTS_REF`);
- lo ejecuta **después** de la pasada de Rector oficial, siempre **dry-run → revisión humana del diff → aplicar → validar** (PHPStan + tests), nunca a ciegas;
- **filtra** las reglas según tu `core_version_requirement` objetivo — algunas reglas migran APIs deprecadas en 11.2+ y eliminadas en 12.0, lo que podría elevar tu mínimo efectivo y romper en 11.0/11.1.

Actívalo/desactívalo con `DRUPILOT_USE_DIGESTS_RULES` (por defecto `true`).

---

## Seguridad y convenciones

- **El idioma de salida es el inglés.** Los identificadores de código, nombres de paquetes y comandos de shell se mantienen en su forma original.
- **Las acciones hacia el exterior siempre se confirman** en modo `semi`; el PAT nunca se persiste en texto plano ni se imprime.
- **Scripts y hooks idempotentes y con fallo seguro**: reejecutar un paso detecta el trabajo existente y lo salta; una herramienta opcional ausente nunca rompe un hook.
- **Los fallos de tests nunca se silencian** — si algo no puede pasar, se documenta el motivo.
- **Nada marcado como incierto se asume** (un set de Rector para PHP 8.5, que requiere Drupal 11.3 o posterior; el hostname del webdriver; la disponibilidad de imagen DDEV): se detecta en runtime y se degrada con gracia.
- **Verificación final** antes de dar un módulo por terminado: un `info.yml` compatible, `phpstan` sin deprecaciones al nivel objetivo, un `run-phpcs.sh` limpio (con el ruleset de PHPCS propio del sujeto si lo trae, y si no `Drupal,DrupalPractice`), `check-port-safety.sh` y `scan-signature-changes.sh` sin hallazgos de error, `verify-core-matrix.sh` sin ninguna pata fallida mientras se declare Drupal 10 y la suite de tests aplicable en verde.
- **Los git hooks del repositorio se respetan; saltárselos nunca es la norma.** Antes de un commit, `scripts/contrib/git-hooks.sh` detecta GrumPHP, husky, lefthook, pre-commit, CaptainHook, `core.hooksPath` y scripts de `.git/hooks`, y el flujo deja que se ejecuten. Solo cuando un hook no puede terminar en la sesión ejecuta sus tareas por separado (`git-hooks.sh --run-equivalents`: phpcs, PHPStan, `php -l`, `composer validate`, y PHPUnit con `--with-tests`, a través de DDEV) y registra en `port-report.md` qué validaciones sustituyeron al hook y qué tareas no tenían equivalente.
- **No se confía ciegamente en Rector.** El `rector.php` generado omite las reglas de modernización de PHP que rompieron ports reales (callbacks de la Form API convertidos en closures, `#[\Override]` decidido solo contra el core del sandbox, propiedades `readonly`, casts `(string)`); ninguna es necesaria para la compatibilidad con Drupal 11.

---

## Resolución de problemas

Ejecuta primero `/drupilot-doctor`: además de los requisitos, sus [comprobaciones de salud](#requisitos) detectan varias de las entradas de abajo (un `phpcs.xml.dist` inválido, el `drupal_root` obsoleto, un toolchain que se sabe roto, poco espacio en disco, restos en tu checkout).

- **Un comando dice que falta un requisito duro.** Ejecuta `/drupilot-doctor` — muestra exactamente qué falta, la versión detectada vs. la requerida, y el comando de instalación para tu plataforma.
- **Docker está instalado pero los comandos siguen fallando.** El daemon debe estar corriendo (`sudo systemctl start docker` en Linux, o lanzar Docker Desktop). `drupilot` comprueba el daemon, no solo el binario.
- **`run-phpunit.sh` termina con código 2 y "PHPUnit is not installed" (preservación `not-verified-blocked`).** La raíz de Drupal no tiene `vendor/bin/phpunit`: `drupal/recommended-project` no lo incluye. Instala `drupal/core-dev` ajustado a tu core — el script muestra el comando exacto, p. ej. `ddev composer require --dev "drupal/core-dev:~11.4.8" -W` — y vuelve a ejecutarlo. Los entornos preparados con una versión publicada anterior de drupilot (0.8.4 o anterior) nunca lo instalaron.
- **Los tests FunctionalJavascript se omiten.** Instala el add-on de Selenium: `ddev add-on get ddev/ddev-selenium-standalone-chrome && ddev restart`.
- **Aparece una carpeta de symlinks espuria `web/modules/custom/<proyecto>/` tras `ddev restart`.** La provoca el hook `symlink-project` de `ddev-drupal-contrib` en el layout recommended-project; `ddev-add-ons.sh` lo desactiva en `.ddev/config.contrib.yaml`. Ese fichero es `#ddev-generated`, así que un `ddev add-on get ddev/ddev-drupal-contrib` posterior restaura el hook — vuelve a ejecutar `/drupilot-setup` (o `ddev-add-ons.sh --contrib`) después.
- **La API de GitLab está bloqueada.** Es lo esperado — la API de drupalcode está restringida por defecto. `drupilot` degrada a una URL de MR de un clic; solo ábrela para crear el MR.
- **El plugin no carga.** Ejecuta `claude plugin validate /ruta/a/drupilot` para revisar el manifiesto y el frontmatter de los componentes.
- **`phpcs` en la raíz de Drupal falla con "Ruleset … is not valid … Comment must not contain '--'", o PHPStan muestra "The drupal_root parameter is deprecated".** Tus `phpcs.xml.dist` / `phpstan.neon` los generó una versión publicada anterior de drupilot (0.8.4 o anterior). Regenéralos (las copias antiguas se guardan en `.drupilot/backups/`): `bash "$CLAUDE_PLUGIN_ROOT/scripts/env/render-templates.sh" --root <drupal_root> --subject-path web/modules/custom/<nombre> --only phpstan,phpcs --force`. Sin `--force` solo muestra el diff.
- **Rector falla con "[ERROR] Could not detect twig set." (o `MissingPrivatePropertyException … RichParser`), o `run-rector.sh` / `install-toolchain.sh` terminan con código 3.** El toolchain instalado es una combinación incompatible: `palantirnet/drupal-rector` 0.21 necesita `rector/rector` < 2.6.2, y `rector/rector` 2.5.x necesita PHPStan 2.2.2. Las versiones publicadas anteriores de drupilot (0.8.4 y anteriores) resolvían los rangos de nuevo y podían instalar justo eso, e informaban del fallo como «0 files would change». Reinstala el conjunto verificado (también refresca el lock): `bash "$CLAUDE_PLUGIN_ROOT/scripts/env/install-toolchain.sh" --dir <drupal_root> --source reference`. Ahora `run-rector.sh` informa de un fallo como `status: "error"` (código 3), nunca como un resultado. Si el toolchain ya coincide con el conjunto verificado, el problema es la configuración de Rector: regenera `rector.php` (como en la entrada anterior): `bash "$CLAUDE_PLUGIN_ROOT/scripts/env/render-templates.sh" --root <drupal_root> --subject-path web/modules/custom/<nombre> --only rector --force`.
- **`run-rector.sh --digests` termina con código 4 (`status: "partial"`, `digests_status: "error"`), p. ej. `[ERROR] Expected an existing class name. Got: "…Rector"`.** Solo falló la pasada de digests generada por IA, normalmente por un fichero de regla roto en un commit upstream de `drupal-digests`. El resultado de la pasada oficial sigue siendo válido y el toolchain está bien, así que no lo reinstales. Fija un commit de digests que se sepa que funciona (`--digests-ref <sha>` o `DRUPILOT_DIGESTS_REF=<sha>`) u omite la capa (`DRUPILOT_USE_DIGESTS_RULES=false`). Un SHA de digests solo se congela en el lockfile cuando su pasada termina con normalidad, así que nunca se fija un commit roto.
- **Rector convirtió callbacks de la Form API `[$this, 'method']` en `$this->method(...)`, o añadió `#[\Override]`, `readonly` o casts `(string)`.** Tu `rector.php` es anterior a la lista de reglas omitidas. `run-rector.sh` regenera en su siguiente ejecución un `rector.php` escrito por una plantilla de drupilot anterior (la copia antigua va a `.drupilot/backups/`); uno escrito a mano se respeta y solo se avisa — añade las exclusiones de `templates/rector.php.tmpl`. Después revierte los cambios convertidos; `check-port-safety.sh` los lista.
- **`check-port-safety.sh` termina con código 3.** Encontró hallazgos de error — p. ej. un plugin cuyo `create()` perdió `implements ContainerFactoryPluginInterface` (`QueueWorkerBase`, `BlockBase`, `FilterBase`, `ActionBase` y `ConditionPluginBase` no la implementan), `new self(` en `create()`, un closure bajo `#submit`/`#ajax`/..., o una propiedad `readonly`/`private` en un formulario o plugin. Cada línea indica el fichero, la línea, la corrección y si lo introdujo el port; corrígelos y vuelve a ejecutarlo. Si el port ya está confirmado, pasa `--base <ref previa al port>` para que la atribución sea correcta.
- **`scan-signature-changes.sh` termina con código 3.** El módulo choca con un cambio de firma de core dentro del rango de core que declara — p. ej. `parent::__construct($config_factory)` en una subclase de `ConfigFormBase` (Drupal 11 exige también `TypedConfigManagerInterface`: pasa `$container->get('config.typed')`, que los cores 10.x antiguos simplemente ignoran), un `getOriginal()` de entidad sin `: ?static` (fatal en 11.2+), o un `hook_entity_operation()` que exige `$cacheability` mientras sigues declarando cores anteriores a 11.3 (déjalo como `?CacheableMetadata $cacheability = NULL`). Cada hallazgo incluye la corrección y la forma compatible con Drupal 10; la severidad sigue al suelo declarado (`^10 || ^11` → 10.0), y `--core-floor X.Y` evalúa con otro.
- **PHPStan sigue listando `user_load_by_name()` (o `text_summary()`, `check_markup()`) tras el port.** Es una deprecación *blanda*: deprecada en 11.4.0 y eliminada en 13.0.0, así que funciona en todos los cores de Drupal 11, y el valor por defecto `DRUPILOT_SOFT_DEPRECATIONS=report` la deja a propósito y la lista en `port-report.md`. Ponlo en `fix` (o ejecuta `/drupilot-refactor`) para reemplazarla; drupilot mantiene entonces funcionando el suelo de core declarado — p. ej. el servicio `TextSummary` solo existe desde 11.4, así que con `^10 || ^11` pasa por `DeprecationHelper::backwardsCompatibleCall()`. Una *dura* (eliminada en 11.0, p. ej. `user_roles()`, que PHPStan reporta como "Function user_roles not found.") siempre bloquea la Fase 1.
- **PHPCS falla con "trim(): Passing null to parameter #1" desde un sniff de `PHPCompatibility` (a menudo como "An error occurred during processing").** El ruleset usa PHPCompatibility pero deja sin definir su config `testVersion` — normalmente porque declara `testVersion` como `<property>` dentro de `<rule ref="PHPCompatibility">`, que PHPCompatibility no lee. `run-phpcs.sh` pasa siempre `--runtime-set testVersion` (el valor de esa propiedad, o `<DRUPILOT_PHP_TARGET>-`), así que no le ocurre; si ejecutas `phpcs` a mano, añade `--runtime-set testVersion 8.3-`, o corrige el ruleset con `<config name="testVersion" value="8.3-"/>`.
- **`run-phpcs.sh` avisa "Project PHPCS ruleset … cannot be used" y cae a Drupal,DrupalPractice.** El ruleset propio del sujeto referencia un estándar o sniff que el banco de pruebas no tiene (p. ej. `Referenced sniff "PHPCompatibility" does not exist`). Instálalo en la raíz de Drupal (p. ej. `ddev composer require --dev phpcompatibility/php-compatibility`) para pasar las reglas del proyecto, o pon `DRUPILOT_PHPCS_RULESET=drupilot` para usar a propósito el estándar por defecto de drupilot.
- **Un `git commit` pide confirmación porque "skips the repository's git hooks".** El comando usó `--no-verify`/`-n` en un repositorio con un hook pre-commit o commit-msg instalado. Deja que el hook se ejecute (dale más tiempo) o, si de verdad no puede ejecutarse aquí, lanza antes `scripts/contrib/git-hooks.sh --subject <dir> --run-equivalents` y conserva su registro para el informe de port. `DRUPILOT_HOOKS_GUARD=off` desactiva la comprobación.
- **`verify-core-matrix.sh` termina con código 3 («Drupal 10.x [reference] — FAIL»).** El módulo usa algo que no tiene el core de Drupal 10 que declara; cada línea `✗` indica el fichero y el mensaje de PHPStan. Casos típicos: `has #[\Override] attribute but does not override any method` (el método padre solo existe en cores más nuevos — quita el atributo), `Access to constant … on an unknown class Drupal\Core\…` (una API añadida en Drupal 11 — protégela con `DeprecationHelper::backwardsCompatibleCall()` o sube el suelo) o `php -l` fallando en PHP 8.1 (una construcción de PHP 8.2+ con un `require.php` `>=8.1`). Corrige el código de forma compatible con Drupal 10, sube el suelo (p. ej. `^10.3 || ^11`) o pasa a `^11`. Los hallazgos solo en `tests/`, las deprecaciones, las reglas orientativas de phpstan-drupal, las clases de módulos contrib que el core de referencia no tiene y los hallazgos que PHP tolera en tiempo de ejecución (líneas `~`: pasar *más* argumentos de los que acepta el método de un core más antiguo, p. ej. la llamada de dos argumentos a `ConfigFormBase::__construct()` en 10.0, y usar el resultado de un método que un core más nuevo declara `: void`) se informan pero nunca hacen fallar una pata. Si no se puede analizar la propia pata base (línea base) de Drupal 11, la pata de Drupal 10 queda `skipped` y el soporte sigue como `declared-not-verified` (código 0), nunca `failed`.
- **`verify-core-matrix.sh` avisa «The PHPStan extension config of … is broken».** Una versión anterior de drupilot ejecutaba el `vendor/bin/composer` del propio banco de pruebas al construir un core de referencia, lo que reescribía el `vendor/phpstan/extension-installer/src/GeneratedConfig.php` del banco de pruebas (y `run-phpstan.sh` fallaba entonces con `Config file …/.drupilot/cores/.build-…/rules.neon does not exist`). Ahora la matriz usa siempre el Composer propio del contenedor, comprueba ese fichero en el banco de pruebas y en cada core de referencia en caché, y lo regenera con `composer install` (o reconstruye el core de referencia). Si sigue diciendo que está roto, ejecuta `ddev composer install` en la raíz de Drupal.
- **La pata de Drupal 10 queda `skipped` y `d10_support` sigue en `declared-not-verified`.** No se pudo construir el core de referencia: sin red (`composer` no llegó a Packagist) o esa versión menor de Drupal no se puede instalar con el PHP del contenedor. También queda `skipped` cuando no se pudo analizar la pata base (línea base) de Drupal 11 (su estado es `error`, p. ej. PHPStan falló en el banco de pruebas): sin esa línea base, los hallazgos de Drupal 10 no se pueden distinguir de los preexistentes. Arregla primero `run-phpstan.sh` en el banco de pruebas. El motivo aparece en el JSON y en el resumen. Vuelve a ejecutarlo con conexión (`--dry-run` muestra qué se construiría); `--refresh` reconstruye un core en caché. Para omitir la comprobación a propósito, usa `DRUPILOT_VERIFY_CORES=off`.
- **`run-phpstan.sh` termina con código 3.** PHPStan falló o no pudo analizar (configuración inválida, ruta inexistente, error fatal), así que no hay veredicto; la causa se muestra en stderr (y en `drupilot.crash` con `--json`). Corrígela y vuelve a ejecutarlo: no es un recuento de hallazgos.
- **En macOS: `bad substitution`, `declare: -A: invalid option` o `sed: 1: "…": invalid command code`.** Las versiones publicadas anteriores de drupilot (0.8.4 y anteriores) usaban sintaxis de bash 4 y `sed -i` de GNU, que un macOS de serie (`/bin/bash` 3.2, `sed` BSD) rechaza. Actualiza el plugin: los scripts y hooks funcionan ahora con bash 3.2 y herramientas BSD, y `scripts/dev/check.sh` rechaza esas construcciones. No necesitas el bash de Homebrew; si lo instalaste, se usa igual de bien.
- **En Debian 12 o Ubuntu 22.04 (jq 1.6): todos los comandos dicen que faltan requisitos, `/drupilot-doctor` no muestra ninguna comprobación, o `layers.sh` falla con "Could not compute the layers".** Las versiones publicadas anteriores de drupilot usaban sintaxis exclusiva de jq 1.7, y jq 1.6 rechazaba esos programas (`jq: error: syntax error, unexpected label` en stderr). Actualiza el plugin; jq 1.6 vuelve a funcionar. Instalar jq 1.7 también lo soluciona.
- **Todos los tests FunctionalJavascript fallan al iniciar la sesión WebDriver, mientras Unit/Kernel/Functional pasan.** El `WebDriverTestBase` de Drupal 11.4 fuerza `w3c` a `false` cuando `MINK_DRIVER_ARGS_WEBDRIVER` pide Chrome sin `"w3c":true` (deprecado en 11.4.0, ver https://www.drupal.org/node/3460567), y la imagen actual de Selenium rechaza esa sesión. El add-on de Selenium fija un valor que funciona; se pierde cuando algo lo sobrescribe — un `.ddev/config.testing.yaml` de un drupilot antiguo, o un valor puesto a mano. Compruébalo con `ddev exec printenv MINK_DRIVER_ARGS_WEBDRIVER` (debe contener `"w3c":true`), regenera la configuración de testing con `render-templates.sh --root <drupal_root> --only testing --force` y luego `ddev restart`.
- **Un comando de Composer lanzado con `ddev exec` estropea el banco de pruebas (p. ej. PHPStan falla después con `Config file …/rules.neon does not exist`).** Un banco de pruebas con `drupal/core-dev` trae su propio `vendor/bin/composer`, que va primero en el `PATH` del contenedor. El contenedor web solo lo oculta al shell de primer nivel (mediante `EXECIGNORE`), así que `ddev exec "timeout 600 composer …"`, `sh -c 'composer …'` o un `bash -c` anidado ejecutan la copia del banco de pruebas, con el autoloader del banco de pruebas: sus plugins escriben entonces en el `vendor/` del banco de pruebas aunque trabajes sobre otro proyecto. Usa `ddev composer …`, o llama al Composer propio del contenedor por su ruta absoluta (`/usr/local/bin/composer`), como hace drupilot. Si el banco de pruebas ya quedó dañado, `ddev composer install` lo repara.
- **El setup o la matriz de cores fallan con "No space left on device", o Docker va lento.** Cada banco de pruebas guarda un proyecto DDEV y unos cientos de MB de árboles de Composer, y la matriz de cores conserva un core de referencia por versión menor de Drupal en el `.drupilot/cores/` del banco de pruebas. `/drupilot-clean` los libera sin perder el trabajo (se conservan informes, estado, parches y las ramas git del módulo; los cores de referencia se van con `--level workspace`); `ddev delete -Oy <proyecto>` y `docker system prune` liberan más. `/drupilot-doctor` informa del espacio libre frente a `requirements.disk_free_min_mb`.
- **Aparecen `.ddev/`, `vendor/`, `.drupilot*` sin seguimiento o symlinks sueltos en el checkout original de tu módulo.** Algo dejó restos del entorno local ahí (un drupilot antiguo, o un sandbox DDEV con el módulo en la raíz). `/drupilot-doctor` los lista, y `scripts/env/origin-hygiene.sh --check --subject <dir>` compara el checkout con el estado registrado antes del port. Mira antes de borrar: `git -C <dir> status --porcelain`, y luego `git -C <dir> clean -n -- .ddev` (simulación) antes de `-f`. drupilot nunca borra nada de tu checkout por su cuenta.

---

## Desarrollo de drupilot

Ejecuta el gate de desarrollo antes de cada commit sobre el propio plugin:

```bash
bash scripts/dev/check.sh          # informe legible; exit 0 ok / 1 algún gate falló
bash scripts/dev/check.sh --json   # resumen por gate legible por máquina
bash scripts/dev/check.sh --smoke  # ejecuta también las pruebas de humo (~15 s)
```

Valida el manifiesto del plugin, comprueba la sintaxis y pasa `shellcheck` por todos los scripts, verifica los bits de ejecución, rechaza construcciones exclusivas de bash 4 / GNU (`${x,,}`, `declare -A`, `sed -i`, `readlink -f`, ... — los scripts deben funcionar con el bash 3.2 de serie de macOS), rechaza variables especiales de bash usadas como variables normales (`GROUPS`, `RANDOM`, `SECONDS`, `UID`, ... — bash ignora en silencio esas asignaciones), rechaza palabras clave de jq usadas como variables de jq o claves abreviadas (`--arg label`, `{module, scope}` — un error de sintaxis en jq 1.6), rechaza literales `<placeholder>` dentro de las líneas `` !`...` `` que se ejecutan al cargar commands/skills/agents, comprueba que las plantillas XML renderizadas estén bien formadas y valida el JSON de `config/`, `hooks/` y `.claude-plugin/`. Las herramientas opcionales (`claude`, `shellcheck`, `xmllint`) se omiten si no están (`--ci` las hace obligatorias). Consulta `--help` para `--only`/`--skip`/`--allow-known`.

El gate opcional `smoke` (`--smoke`, implícito con `--ci`) ejecuta `scripts/dev/smoke.sh`: pruebas de humo que no necesitan Docker, DDEV ni PHP y comprueban, entre otros, el `--help` de los scripts, el gate de requisitos (`preflight`, `detect-php`), `next-step` y la sonda de estado, los hooks, los scripts de análisis (`check-port-safety`, `scan-signature-changes`, `lint-extension-metadata`, `layers`, `patterns`, `port-summary`, el target de core y la pasada de atributos), la resolución del espacio de trabajo (raíces de proyecto, bancos de pruebas compartidos y de monorepo), el registro de elecciones en pestañas (`choices`) y varios `--dry-run` sobre los fixtures de `tests/fixtures/` (`legacy_widgets` y un `monorepo` pequeño; `tests/fixtures/*.EXPECTED.md` documenta los problemas que llevan plantados). Trabaja sobre copias en un directorio temporal con su propio `HOME`, así que nunca toca el árbol ni tu estado de drupilot. Ejecuta `bash scripts/dev/smoke.sh --list` para ver la lista completa de nombres de las pruebas y `--only` para elegir algunas.

GitHub Actions (`.github/workflows/ci.yml`) ejecuta el mismo gate en Ubuntu y macOS, una segunda vez en macOS con el `/bin/bash` 3.2 de serie, dentro del contenedor `bash:3.2` (herramientas de BusyBox) y del contenedor `debian:12-slim` (mawk, jq 1.6), y ejecuta `claude plugin validate .` en un job propio tras instalar la CLI de Claude Code desde npm.

El gate también ejecuta las pruebas unitarias (`tests/unit/`), las instantáneas del contrato 0.9 (`tests/contract/`), las evals estáticas del router (`tests/evals/`), la validación de esquemas de los artefactos persistidos (`schemas/`) y las comprobaciones de la documentación; `--smoke` añade las salidas golden (`scripts/dev/golden.sh`). El sitio de documentación vive en `docs/` (solo en inglés): previsualízalo con `docker compose up docs` (http://localhost:8000) y regenera sus páginas de referencia con `bash scripts/dev/gen-docs.sh`. Cómo funciona cada comprobación está en `docs/contributing/checks.md`.

---

## Licencia

MIT. Ten en cuenta que las reglas opcionales de `dbuytaert/drupal-digests` son de terceros, sin licencia, y nunca se empaquetan con este plugin — se descargan en runtime a una caché local.
