<p align="center">
  <img src="assets/drupilot.png" alt="drupilot — Code. Fly. Conquer. Un plugin de Claude Code para portar de Drupal 9/10 a Drupal 11" width="100%">
</p>

# drupilot

> Un plugin de Claude Code que porta módulos y temas de Drupal 9/10 a **Drupal 11**: evalúa la viabilidad, aplica la portabilidad (compatibilidad mínima y/o un refactor completo al "estilo Drupal 11"), adapta y ejecuta la suite de tests **completa** dentro de DDEV, y te ayuda a **contribuir el resultado a Drupal.org** (issue fork + Merge Request, o un patch legacy).

*Léelo en inglés: [README.md](README.md).*

`drupilot` = **Drupal** + **co-pilot** (copiloto). Es tu copiloto en el viaje D9/10 → D11: nunca se niega ante un módulo difícil — si un refactor completo es desproporcionado, igual te entrega un plan por etapas que respeta la funcionalidad original y te deja a ti la decisión final.

> **Nota sobre el idioma:** todo el contenido funcional del plugin (mensajes, informes, prompts) está **en inglés** a propósito. Este `README_es.md` es la traducción al español de la documentación; el resto del plugin no contiene español.

---

## Índice

- [Qué hace](#qué-hace)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Inicio rápido](#inicio-rápido)
- [Comandos](#comandos)
- [Filosofía de portabilidad en dos fases](#filosofía-de-portabilidad-en-dos-fases)
- [Qué es automático vs. dónde decide la IA](#qué-es-automático-vs-dónde-decide-la-ia)
- [Modo autónomo (manos fuera)](#modo-autónomo-manos-fuera)
- [Configuración](#configuración)
- [Determinismo (reproducible por defecto)](#determinismo-reproducible-por-defecto)
- [Casos de uso](#casos-de-uso)
- [Cómo funciona (arquitectura)](#cómo-funciona-arquitectura)
- [La capa complementaria drupal-digests](#la-capa-complementaria-drupal-digests)
- [Seguridad y convenciones](#seguridad-y-convenciones)
- [Resolución de problemas](#resolución-de-problemas)
- [Desarrollo de drupilot](#desarrollo-de-drupilot)
- [Licencia](#licencia)

---

## Qué hace

- **Estudio de viabilidad** — un análisis estático no destructivo (Rector en dry-run, PHPStan, PHPCS, y opcionalmente Upgrade Status) que estima qué parte del trabajo es auto-corregible vs. manual, clasifica las rupturas duras (Twig 3, CKEditor 5, jQuery UI, Symfony 7), revisa el `info.yml` y el soporte D11 de las dependencias contrib, recomienda un **target de compatibilidad de core** (`^11` vs `^10 || ^11`, el `require.php` que implica y un veredicto SemVer de subida de versión), y produce un informe markdown más un **plan de portabilidad por etapas** con un veredicto de esfuerzo S/M/L/XL.
- **Portabilidad mínima (Fase 1)** — el conjunto de cambios más pequeño para que el módulo/tema funcione en Drupal 11 **respetando la funcionalidad original**. Motor: `palantirnet/drupal-rector`, una capa opcional de reglas IA (`dbuytaert/drupal-digests`) y ajustes manuales puntuales.
- **Refactor completo (Fase 2, opt-in)** — una reescritura a las mejores prácticas modernas de Drupal 11: atributos PHP 8 para plugins, inyección de dependencias, tipados estrictos, cero deprecaciones, `Drupal` + `DrupalPractice` limpios y suite de tests en verde.
- **Tests** — descubre, adapta y ejecuta la suite PHPUnit completa (Unit / Kernel / Functional / FunctionalJavascript) dentro de DDEV (con Selenium para JS), iterando hasta verde y reportando cobertura. Los fallos **nunca** se silencian.
- **Contribución** — prepara y (opcionalmente) publica el resultado a Drupal.org mediante el flujo moderno issue-fork + Merge Request, o un patch legacy, en modo **semi-automático** (confirma cada acción externa) o **totalmente automático**. Genera el **resumen del issue y los valores recomendados de los campos obligatorios** (Title, Category, Priority, Version, Component, Assigned) para pegarlos en el formulario web, además de un breve **comentario**. Siempre se genera un `.patch` junto al MR y se **verifica que aplica limpio** sobre la versión a la que se refiere, para que tú (o cualquiera) puedas adjuntarlo y aplicarlo en el issue antes de que el maintainer lo fusione.
- **Patches, desacoplados de la contribución** — obtén el `.patch` de la portabilidad cuando quieras con **`/drupilot-patch`**: offline, sin push, sin cuenta de Drupal.org. Elige un patch local de pruebas (`MODULE-port-to-drupal-11.patch`) **o** uno con el nombre de la convención issue-comment para adjuntarlo a un issue y probarlo ya — y contribuye el Merge Request más tarde, como paso aparte.
- **Tú mantienes el control** — las decisiones de peso son **elecciones en pestañas** (target de core, target de PHP, qué reglas digests aplicar, alcance del refactor, hacer push o no), con la recomendación preseleccionada y tus respuestas recordadas por proyecto. Nada importante ocurre en silencio.
- **Información, no solo salida** — un **boletín** por portabilidad (`port-report.md`: qué cambió y por qué, el veredicto de preservación), un **panel de preparación D11 de las dependencias** (qué deps contrib bloquean la portabilidad), una **búsqueda de issue upstream** (¿hay alguien ya portando esto?) y un **explicador de deprecaciones** que convierte la salida críptica en un fix + un enlace a los change-records.

El target de PHP por defecto es **8.3** y es totalmente configurable; todo (sets de Rector, nivel de PHPStan, sniffs de PHPCS, `php_version` de DDEV) deriva de un único ajuste. Las elecciones del flujo persisten en un `.drupilot.json` por proyecto (leído entre las variables de entorno y los valores por defecto).

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

---

## Instalación

`drupilot` se distribuye como un marketplace de un solo plugin, así que la instalación son dos pasos.

**Desde una copia local:**

```text
/plugin marketplace add /ruta/a/drupilot
/plugin install drupilot@drupilot
```

**Desde GitHub (una vez publicado):**

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

# 2. Apunta drupilot a tu módulo/tema y deja que te guíe
/drupilot web/modules/custom/my_module

# …o conduce los pasos tú mismo:
/drupilot-setup                         # levanta un sitio Drupal 11 con DDEV + toolchain
/drupilot-assess  web/modules/custom/my_module
/drupilot-port    web/modules/custom/my_module
/drupilot-test    web/modules/custom/my_module
/drupilot-refactor web/modules/custom/my_module   # Fase 2 opcional
/drupilot-contribute web/modules/custom/my_module # solo proyectos contrib
```

### Apuntando a un checkout suelto

No necesitas un sitio Drupal para empezar. Apunta drupilot a un checkout pelado de un módulo/tema y construye un **banco de pruebas Drupal 11 en un directorio hermano** `<padre>/<machine_name>-d11/`, colocando el sujeto bajo `web/modules/custom/<machine_name>` (los temas van a `web/themes/custom/...`). **Tu checkout original queda intacto** — drupilot ya no monta Drupal encima de él, así que sus ficheros y su `composer.json` nunca se mezclan.

```text
padre/
├── my_module/                 # tu checkout — sin tocar
└── my_module-d11/             # el banco de pruebas que construye drupilot
    ├── .drupilot/             # salidas para el desarrollador, visibles e ignoradas en git
    └── web/modules/custom/my_module
```

Cómo llega el sujeto ahí lo controla `DRUPILOT_PLACEMENT` (`move` / `symlink` / `copy`); la ubicación del banco de pruebas, `DRUPILOT_WORKSPACE_DIR` (ver [Configuración](#configuración)). Un módulo que **ya está dentro** de una raíz de Drupal conserva ese layout — esto solo aplica a checkouts sueltos.

**Higiene del origen.** Antes de colocar el sujeto, drupilot registra el `git status` del checkout de origen (estado oculto, nunca dentro del árbol); `scripts/env/origin-hygiene.sh --check` informa después de cualquier entrada nueva sin seguimiento atribuible a drupilot (`.ddev/`, `vendor/`, `node_modules/`, `.phpstan-cache/`, configuración generada, parches, enlaces simbólicos que salen del árbol) — solo informa, nunca borra nada — y el informe del port muestra el resultado. Una colocación `copy` no copia los restos del entorno local (`.ddev/`, `vendor/`, `.drupilot*`, `.phpstan-cache/` en la raíz, `node_modules/` a cualquier profundidad) y descarta los enlaces simbólicos que apuntan fuera del checkout (`--no-exclude` recupera la copia literal). Los ficheros propios de drupilot dentro de tu repo (el `.drupilot.json` del lado del sujeto, el parche local) se ocultan mediante el `.git/info/exclude` **local** del repo, nunca con su `.gitignore` versionado.

### La carpeta `.drupilot/`

Las salidas destinadas al desarrollador viven en un único directorio **visible e ignorado en git** `.drupilot/` en la raíz de Drupal: el **boletín** del port (`port-report.md`), el **informe de viabilidad** (`viability-report.md`), el HTML de cobertura de tests y el `.patch` local. Se ignora en git automáticamente para que nunca acabe en tu parche, y puedes apuntarlo a otro sitio con `DRUPILOT_ARTIFACTS_DIR`. La caché legible por máquina y el lockfile de determinismo se quedan deliberadamente **ocultos bajo `$HOME`** para que no puedan filtrarse a un parche.

---

## Comandos

| Comando | Qué hace |
| --- | --- |
| `/drupilot [sujeto] [full\|auto]` | **Router / flujo guiado.** Detecta el estado actual (entorno, último assess, fase) y recomienda el siguiente paso. `full` ejecuta todo el flujo con confirmaciones; `auto` lo ejecuta **sin intervención** (ver más abajo). |
| `/drupilot-doctor [install]` | **Verificación de requisitos.** Tabla de estado por plataforma (Docker + daemon, DDEV, git, composer/php, jq, SSH/PAT) con instrucciones de instalación e instalación asistida opcional (con confirmación). |
| `/drupilot-setup` | Levanta un sitio **Drupal 11 con DDEV**, instala los add-ons (`ddev-drupal-contrib`, Selenium) y el toolchain de desarrollo de Composer (incluido `drupal/core-dev`, ajustado al core instalado, que aporta PHPUnit), y escribe `rector.php` / `phpstan.neon` / `phpcs.xml.dist` / entorno de tests desde plantillas. Idempotente. |
| `/drupilot-assess [sujeto]` | Produce el **informe de viabilidad** + plan por etapas con veredicto S/M/L/XL. |
| `/drupilot-port [sujeto]` | **Portabilidad mínima (Fase 1).** Rector oficial + (opcional) reglas digests filtradas por target + ajustes ad-hoc + cambios manuales mínimos; deja el código compilando sin deprecaciones bloqueantes. |
| `/drupilot-refactor [sujeto]` | **Refactor completo (Fase 2)** (opt-in): el "estilo Drupal 11", PHPStan nivel 5–6, PHPCS limpio. |
| `/drupilot-test [sujeto]` | Descubre, adapta y ejecuta **toda** la suite de tests en DDEV (Selenium para JS); itera hasta verde; reporta cobertura. |
| `/drupilot-patch [sujeto] [issue]` | **Obtén el `.patch`, desacoplado de contribuir.** Offline, sin push, sin verja: un patch local de pruebas, o uno con nombre para un comentario de issue de Drupal.org. Pruébalo ya, contribuye el MR después. |
| `/drupilot-contribute [sujeto] [issue]` | Publica a **Drupal.org**: issue fork + Merge Request (o patch legacy), en modo semi o auto. Solo invocable por el usuario; nunca expone el PAT. |
| `/drupilot-status` | Resumen de solo lectura: entorno, target de PHP, fase actual, último assess, estado de tests (con el veredicto de preservación), el lock de reproducibilidad congelado y el siguiente paso sugerido. |

---

## Filosofía de portabilidad en dos fases

1. **Fase 1 — Compatibilidad mínima (por defecto).** Los cambios mínimos para que el módulo/tema funcione en Drupal 11 respetando la funcionalidad original y **sin colisionar** con lo que Drupal 11 ya ofrece. Motor: `drupal-rector` + ajustes manuales puntuales. Sin cambios de arquitectura.
2. **Fase 2 — Refactor "estilo Drupal 11" (opt-in).** Una reescritura a las mejores prácticas modernas: atributos PHP 8 para plugins, inyección de dependencias, tipado estricto, cero deprecaciones, cero errores de PHPStan al nivel objetivo, cumplimiento total de `Drupal` + `DrupalPractice` y tests completos en verde.

Un **estudio de viabilidad** siempre se ejecuta primero como gate de decisión. Si el refactor es desproporcionado (umbral configurable), `drupilot` no se niega — igual entrega un plan de portabilidad por etapas que respeta la funcionalidad original, y te deja la decisión.

**Cómo se verifica que «se respeta la funcionalidad original».** Que la suite de tests adaptada siga en **verde es el gate de preservación** en ambas fases — ese verde es la prueba de que el comportamiento se preserva. Las adaptaciones de los tests solo cambian la *forma* del test (API de PHPUnit/Drupal), nunca *lo que verifica*; una regresión de comportamiento se arregla en el código, nunca relajando un test. Si el módulo **no tiene tests**, `drupilot` informa de que la preservación **no está verificada** y recomienda añadirlos — no los inventa. Si hay tests pero no pueden ejecutarse (falta PHPUnit/`drupal/core-dev`, Selenium inaccesible), informa **no verificada (bloqueada)** con el motivo — nunca una regresión falsa ni un falso «sin tests».

---

## Qué es automático vs. dónde decide la IA

drupilot reparte el trabajo en dos. **Los scripts deterministas** hacen el trabajo mecánico y repetible y miden el resultado; **la IA (Claude) aporta el criterio** — revisa, decide qué aplicar, arregla lo que no es mecánico y encadena los pasos. Las decisiones de peso las sigues aprobando tú (las elecciones en pestañas).

**Lo hacen los scripts, sin IA:**

- *Tocan el código:* Rector oficial (`palantirnet/drupal-rector`), la capa Rector de digests (reglas creadas por IA, pero ejecutadas como un config congelado y fijado por versión), `phpcbf` (estándares de código auto-corregibles) y el hook `PostToolUse` (pasa `phpcbf` en cada fichero Drupal que editas).
- *Solo miden / informan:* `phpcs` (reporta lo que `phpcbf` no pudo arreglar), PHPStan (deprecaciones + errores de tipo), el gate de requisitos de preflight, la detección de PHP/core, el panel de preparación de dependencias, las **comprobaciones de seguridad del port** (`check-port-safety.sh`: un `create()` sin `ContainerFactoryPluginInterface`/`ContainerInjectionInterface` en su ascendencia real, un `use` eliminado que sigue referenciado, `new self(` en `create()`, closures bajo claves de callback de la Form/Render API, propiedades `private`/`readonly` en clases que se serializan, `#[\Override]` mientras el rango de core incluya Drupal 10, discrepancias de mayúsculas en nombres de clase — cada una atribuida al port o preexistente vía git), el **análisis de cambios de firma de core** (`scan-signature-changes.sh`: el módulo comparado con un catálogo verificado de cambios de firma de Drupal 10 → 11 en el core más bajo que declara — una subclase de `ConfigFormBase`/`ContentTranslationController` que pasa menos argumentos de los necesarios al constructor, un `getOriginal()`/`setOriginal()`/`buildRevisionCacheId()` propio que core añade en 11.2/11.3, un `hook_entity_operation()`/`_alter()` que exige el parámetro que solo pasa 11.3, un `#[\Override]` en un método que no existe en los cores declarados más antiguos), el **clasificador de deprecaciones** (`classify-deprecations.sh`: separa las deprecaciones de PHPStan en *duras* — eliminadas en una major ≤ la objetivo, p. ej. `user_roles()`, que desaparece en 11.0 — y *blandas* — eliminadas solo en una major posterior, p. ej. `user_load_by_name()`/`text_summary()`/`check_markup()`, deprecadas en 11.4 y eliminadas en 13.0 — e indica qué hace `DRUPILOT_SOFT_DEPRECATIONS` con cada una) y los generadores de parche e informes. Estos **nunca tocan tu código**.

**Dónde actúa la IA:**

- **Revisa cada dry-run de Rector** y decide si aplicarlo — nunca aplica a ciegas.
- **Elige qué reglas digests aplicar**, pre-marcando las que elevarían tu suelo de core en silencio.
- **Arregla lo que Rector no cubre** — genera una regla ad-hoc o edita a mano (`DRUPILOT_GENERATE_RULES`).
- **Hace los cambios manuales que Rector no puede** — `core_version_requirement`, `require.php`, Twig 3, CKEditor 5, jQuery UI.
- **Conduce el bucle de validación** — lee lo que reportan `phpcs` / PHPStan y lo arregla hasta dejarlo limpio.
- **Adapta los tests** a D11; ante un fallo de comportamiento arregla el **código**, nunca el test.
- **Reescribe al "estilo Drupal 11"** en la Fase 2 — atributos, inyección de dependencias, tipados estrictos, eliminación de deprecaciones.
- **Propone las decisiones de peso** (target de core, alcance del refactor, contribuir o no) — eliges tú.

**Cuándo actúa la IA — el patrón.** La IA es el director de orquesta: los scripts no se llaman entre sí. La IA ejecuta uno, lee su salida, decide el siguiente y lo ejecuta. Así que actúa **antes** de cada script (decidir si lo lanza y cómo) y **después** de él (leer el resultado y arreglar lo que queda), además de en las pestañas de decisión. La única excepción es el **hook `PostToolUse`**, que pasa `phpcbf` por su cuenta tras cada edición de fichero — sin IA en el bucle.

**Los hooks — automáticos, los dispara el harness.** Los hooks son scripts deterministas que **dispara el propio Claude Code ante un evento** — ni la IA ni tú los invocáis. El hook es el automatismo; la IA o tú sois los *destinatarios* de lo que decide:

| Hook | Cuándo actúa | Qué hace | Su salida va |
| --- | --- | --- | --- |
| `session-detect-env` | al iniciar la sesión | resume tu entorno + target de PHP | a la **IA** (como contexto) |
| `post-edit-lint` | tras cada edición de fichero (Write/Edit) | ejecuta `phpcbf` → **edita el fichero**, luego reporta lo que queda | a la **IA** (para corregir el resto) |
| `guard-contrib` | antes de cada comando Bash | detecta un `git push` / MR hacia el exterior | **a ti** (pide confirmación) |

Así que un hook nunca es IA ni una decisión humana en sí mismo — es el automatismo. `post-edit-lint` es el único trozo que cambia código del todo por su cuenta; `guard-contrib` es un automatismo cuyo único propósito es volver a meterte **a ti** en el bucle antes de que algo salga de tu máquina. Actívalos/desactívalos con `DRUPILOT_POST_EDIT_LINT` y `DRUPILOT_SESSION_CONTEXT` (ver [Configuración](#configuración)); la verja de contribución siempre pregunta en modo `semi` y en cualquier ejecución autónoma.

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
2. **Dos capas de "sin preguntas".** La palabra de modo `auto` solo relaja los *gates propios* de drupilot. Bash/Edit/Write siguen pasando por el sistema de permisos de Claude Code, así que una ejecución realmente desatendida necesita además un modo de permisos permisivo:

```bash
# Interactivo pero desatendido (acepta los edits automáticamente):
claude --permission-mode acceptEdits

# Totalmente headless (CI / scripts):
export DRUPILOT_AUTONOMOUS=true
export DRUPILOT_GENERATE_RULES=auto    # el orquestador ya lo trata como auto en este modo
claude -p "/drupilot web/modules/custom/my_module auto" --permission-mode bypassPermissions
```

En modo autónomo `DRUPILOT_GENERATE_RULES` se trata como `auto` (ponlo en `off` para que la generación de reglas ad-hoc se quede en solo-informar). Todo sigue estando gateado y siendo idempotente: un requisito duro ausente detiene esa etapa limpiamente, y reejecutar salta el trabajo ya hecho. En cambio, `full` ejecuta el mismo pipeline pero **se detiene a pedir tu confirmación** y deja refactor/contribución como opt-in.

---

## Configuración

Los valores por defecto están en `config/defaults.json`. **Cada clave `DRUPILOT_*` puede sobreescribirse con una variable de entorno del mismo nombre** (la variable de entorno siempre gana). Un **`.drupilot.json`** por proyecto en la raíz de Drupal se lee **entre** el entorno y los valores por defecto — ahí se recuerdan las elecciones en pestañas que haces (target de core, target de PHP, alcance del refactor, modo de contribución) para que las ejecuciones posteriores no vuelvan a preguntar. Se ignora en git automáticamente para que nunca acabe en un parche.

| Variable | Por defecto | Efecto |
| --- | --- | --- |
| `DRUPILOT_PHP_TARGET` | `8.3` | Versión de PHP destino (controla Rector / PHPStan / PHPCS / DDEV). |
| `DRUPILOT_DRUPAL_TARGET` | `^11` | Rango de core destino. |
| `DRUPILOT_CORE_TARGET_STRATEGY` | `auto` | Decisión de compatibilidad de core: `auto` (mantiene `^10 \|\| ^11` mientras sea retrocompatible, pasa a `^11` ante una ruptura BC / refactor), `d11-only` o `keep-d10`. Mantener D10 declara además un suelo composer `require.php` (ver `DRUPILOT_REQUIRE_PHP_FLOOR`), y la elección produce un veredicto SemVer de subida de versión. |
| `DRUPILOT_KEEP_D10` | _(legacy)_ | Override booleano legacy de la estrategia (`true` → mantener D10, `false` → solo D11). Solo se respeta si se exporta; prefiere `DRUPILOT_CORE_TARGET_STRATEGY`. |
| `DRUPILOT_REQUIRE_PHP_FLOOR` | `detect` | Al mantener `^10 \|\| ^11`, cómo fijar el `require.php` de composer: `detect` deriva el suelo real de un escaneo heurístico del código portado (p. ej. `>=8.1` si no usa construcciones de PHP 8.2/8.3, para soporte real de Drupal 10); `target` mantiene el conservador `>=<target de php>`. Bajar el suelo es best-effort — confírmalo con PHPCompatibility. |
| `DRUPILOT_PLACEMENT` | `move` | Cómo se coloca un checkout suelto en el banco de pruebas hermano: `move` lo reubica (sin pérdida — sigue siendo un repo git en la nueva ruta), `symlink` deja tu checkout donde está y lo enlaza (un destino fuera del banco de pruebas no es visible dentro del contenedor DDEV, así que las herramientas vía `ddev exec` no lo ven — úsalo para trabajo en el host), `copy` lo duplica sin los restos del entorno local (`.ddev/`, `vendor/`, `node_modules/`, …) ni los enlaces simbólicos que salen del checkout. |
| `DRUPILOT_WORKSPACE_DIR` | _(vacío)_ | Ruta explícita para la raíz del banco de pruebas de Drupal. Vacío significa un hermano `<padre>/<machine_name>-d11`. |
| `DRUPILOT_ARTIFACTS_DIR` | _(vacío)_ | Override del directorio de salidas visible `.drupilot/`. Vacío significa `<raíz>/.drupilot`. |
| `DRUPILOT_DDEV_CREATE_TIMEOUT` | `900` | Segundos que `/drupilot-setup` deja correr `ddev composer create-project` antes de pararlo con un error claro (`0` = sin límite). Necesita `timeout` (o `gtimeout` en macOS); sin él el paso no tiene límite. |
| `DRUPILOT_CODER_CONSTRAINT` | `^8.3` | Rama de `drupal/coder` (PHPCS 3.x vs 4.x). |
| `DRUPILOT_PHPSTAN_LEVEL` | `2` | Nivel base de PHPStan (detección de deprecaciones). |
| `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` | `6` | Nivel de PHPStan usado en la fase de refactor. |
| `DRUPILOT_VIABILITY_THRESHOLD` | `medium` | Umbral para el aviso de "refactor grande". |
| `DRUPILOT_CONTRIB_MODE` | `semi` | `semi` (confirma acciones externas) o `auto`. |
| `DRUPILOT_ISSUE_TITLE` | `Drupal 11 compatibility` | Título por defecto del issue generado en Drupal.org. |
| `DRUPILOT_ISSUE_CATEGORY` | `Task` | Category por defecto del issue (`bug report` / `task` / `feature request` / `support request` / `plan`). |
| `DRUPILOT_ISSUE_PRIORITY` | `Normal` | Priority por defecto del issue (`critical` / `major` / `normal` / `minor`). |
| `DRUPILOT_ISSUE_COMPONENT` | `Code` | Component por defecto del issue. La lista es **específica de cada proyecto** — verifícalo contra los componentes propios del proyecto. |
| `DRUPILOT_ISSUE_ASSIGNEE` | `self` | `self` (asignar a la cuenta que abre el issue) o `unassigned`. |
| `DRUPILOT_USE_DIGESTS_RULES` | `true` | Usar la capa complementaria `drupal-digests` tras el Rector oficial. |
| `DRUPILOT_DIGESTS_REF` | `main` | Commit/tag del repo `drupal-digests`, para reproducibilidad. |
| `DRUPILOT_GENERATE_RULES` | `ask` | Generar reglas Rector ad-hoc para deprecaciones no cubiertas: `ask` / `auto` / `off`. |
| `DRUPILOT_SOFT_DEPRECATIONS` | `report` | Qué hace la Fase 1 con las deprecaciones *blandas* — eliminadas solo en una major posterior de Drupal, así que siguen funcionando en todos los cores de Drupal 11 (p. ej. `user_load_by_name()`, `text_summary()`, `check_markup()`: deprecadas en 11.4.0, eliminadas en 13.0.0): `report` (las lista en los informes de viabilidad y de port — símbolo, deprecada en, eliminada en, esfuerzo — sin tocar el código), `defer` (las lista en *aplazado a la Fase 2*) o `fix` (las corrige cuando el reemplazo existe en el suelo de core declarado, mediante `DeprecationHelper::backwardsCompatibleCall()` cuando solo existe en cores más nuevos, y si no las aplaza). Las deprecaciones *duras* (eliminadas en una major ≤ la objetivo, p. ej. `user_roles()`) se corrigen siempre y son las únicas que cuentan en el veredicto de esfuerzo; la Fase 2 elimina también las blandas. |
| `DRUPILOT_AUTONOMOUS` | `false` | Modo manos fuera (equivale a la palabra de modo `auto`): setup→assess→port→refactor→test sin intervención, escribe el patch local, **nunca** contribuye. Ver [Modo autónomo](#modo-autónomo-manos-fuera). |
| `DRUPILOT_DETERMINISTIC` | `true` | Reproducibilidad (activado por defecto): congela el Drupal core, la toolchain de desarrollo, el SHA de digests y los add-ons de DDEV resueltos en un `drupilot-lock.json` por proyecto y los reutiliza en ejecuciones posteriores. Ponlo a `false` para resolver todo de nuevo cada vez y refrescar el lock. Ver [Determinismo](#determinismo-reproducible-por-defecto). |
| `DRUPILOT_TOOLCHAIN_SOURCE` | `auto` | De dónde toma `install-toolchain.sh` las versiones de la toolchain de desarrollo: `auto` (el lock del proyecto cuando fija el conjunto conocido-bueno completo; si no, la referencia conocida-buena que trae el plugin, `config/toolchain-reference.json`; los rangos de `.packages` cuando `DRUPILOT_DETERMINISTIC=false`), `reference` (siempre el conjunto conocido-bueno — la vía de reparación) o `range` (resolución nueva). |
| `DRUPILOT_POST_EDIT_LINT` | `autofix` | El lint incremental de PostToolUse: `autofix` (ejecuta phpcbf + phpcs, y **avisa** cuando modifica un fichero), `report` (solo phpcs, nunca edita ficheros) u `off`. Es consciente de fase — en la Fase 1 saca solo **errores** de compatibilidad, dejando los warnings de estilo para el refactor. |
| `DRUPILOT_SESSION_CONTEXT` | `on` | Interruptor `on`/`off` del resumen de entorno de SessionStart. |
| `DRUPILOT_REFACTOR_SCOPE` | _(se pregunta)_ | Conjunto persistido de modernizaciones de Fase 2 a aplicar (atributos / DI / tipados estrictos / final / deprecaciones). Normalmente se elige con el multi-select de `/drupilot-refactor` y se recuerda en `.drupilot.json`. |
| `DRUPILOT_CHOICE_<KEY>` | — | Pre-responde una elección en pestaña concreta de forma no interactiva (p. ej. `DRUPILOT_CHOICE_CORE_TARGET`), para que no se pregunte. |

Otras variables de entorno útiles: `DRUPILOT_GITLAB_PAT` (tu Personal Access Token de GitLab, leído solo en runtime, nunca persistido), `DRUPILOT_ASSUME_YES=1` (saltar confirmaciones en ejecuciones no interactivas), `NO_COLOR=1`.

Ejemplo — apuntar a PHP 8.4 y abandonar el soporte de Drupal 10 durante una sesión:

```bash
export DRUPILOT_PHP_TARGET=8.4
export DRUPILOT_CORE_TARGET_STRATEGY=d11-only   # solo ^11 (abandona Drupal 10)
```

---

## Determinismo (reproducible por defecto)

Portar el mismo módulo dos veces debería dar el mismo resultado. drupilot es **determinista por defecto** (`DRUPILOT_DETERMINISTIC=true`): la primera vez que resuelve las partes móviles de un port las **congela** en un `drupilot-lock.json` por proyecto (guardado en el directorio de estado de drupilot, no en tu árbol de proyecto) y las **reutiliza** en ejecuciones posteriores:

- la versión exacta de **Drupal core** y las versiones de la **toolchain de desarrollo** (`drupal-rector` y su motor `rector/rector`, PHPStan + extensiones, `coder`/PHPCS, Drush, `drupal/core-dev`) leídas del `composer.lock` generado;
- el **commit (SHA) de digests** al que resolvió la rama `main` — así la capa de reglas generadas por IA queda fija para el proyecto aunque su ref por defecto siga siendo `main`;
- las versiones de los **add-ons de DDEV** instalados.

Funciona como un `composer.lock`: los rangos de versión en `config/defaults.json` siguen siendo flexibles, pero el lock fija exactamente lo que se usó. `scripts/env/lock-sync.sh` lo captura/actualiza (`ddev-up.sh`, `ddev-add-ons.sh` e `install-toolchain.sh` lo llaman automáticamente).

**Conjunto de referencia conocido-bueno.** Un proyecto que aún no tiene lock no resuelve de nuevo los rangos de la toolchain: `scripts/env/install-toolchain.sh` instala la **matriz conocida-buena** que trae el plugin, `config/toolchain-reference.json` — versiones exactas de `drupal-rector`, `rector/rector`, PHPStan + extensiones, `coder`, Drush y `upgrade_status` verificadas juntas de principio a fin. Así, un banco de pruebas nuevo creado después de una release rota aguas arriba (por ejemplo `rector/rector` 2.6.2+, que hace fallar a `drupal-rector` 0.21) sigue recibiendo un conjunto que funciona. Cada instalación termina con un **smoke test** (un dry-run de Rector con el set de Drupal 10 más `phpstan --version`) y sale con código 3, mostrando las versiones instaladas frente a las conocidas-buenas, cuando la toolchain está rota.

**Vía de escape:** pon `DRUPILOT_DETERMINISTIC=false` para ignorar el lock, resolver todo de nuevo (lo más reciente de cada rango, el `main` vivo para digests) y refrescar el lock. `lock-sync.sh --refresh` hace lo mismo solo para el SHA de digests.

Más allá de las versiones, drupilot mantiene el *proceso* objetivo: orden de ficheros estable, un baremo numérico S/M/L/XL, greps fijos para las rupturas duras, y un criterio de "hecho" juzgado únicamente por Rector/PHPStan/PHPCS + la suite de tests.

---

## Casos de uso

### 1. "¿Merece la pena portar este módulo?" — solo evaluación

```text
/drupilot-assess web/modules/custom/my_module
```

Obtienes un informe markdown (cacheado para más tarde) que clasifica cada hallazgo como auto-corregible (Rector) o manual, lista las rupturas duras, el estado del `info.yml` y el soporte D11 de las dependencias contrib, y un veredicto **S/M/L/XL** con un plan por etapas. No se modifica nada.

### 2. Portabilidad guiada de principio a fin de un módulo custom

```text
/drupilot web/modules/custom/my_module
```

El router comprueba tu entorno, ejecuta el assess, aplica la portabilidad de Fase 1, ejecuta la suite de tests en DDEV y reporta en cada paso — deteniéndose para pedir confirmación antes de cualquier acción externa. Te dice exactamente qué va a hacer antes de hacerlo. Al terminar la portabilidad escribe un `MODULE-port-to-drupal-11.patch` local para que puedas revisar o probar el cambio de inmediato.

Para que los agentes lo hagan todo sin pausas, añade `auto` (ver [Modo autónomo](#modo-autónomo-manos-fuera)):

```text
/drupilot web/modules/custom/my_module auto
```

### 3. Solo portabilidad mínima (Fase 1), sin refactor

```text
/drupilot-setup
/drupilot-port web/modules/custom/my_module
/drupilot-test web/modules/custom/my_module
```

La funcionalidad permanece idéntica; el módulo queda compatible con D11 sin deprecaciones bloqueantes. Ideal cuando quieres el diff más pequeño y seguro.

### 4. Modernizar al "estilo Drupal 11" (Fase 2)

```text
/drupilot-refactor web/modules/custom/my_module
```

Convierte anotaciones a atributos PHP 8, introduce inyección de dependencias y tipados estrictos, elimina toda deprecación, sube PHPStan a nivel 5–6 y mantiene la suite en verde. Cada cambio significativo se explica.

### 5. Ejecutar la suite de tests completa en DDEV

```text
/drupilot-test web/modules/custom/my_module --type all --coverage
```

Ejecuta Unit, Kernel, Functional y FunctionalJavascript (Selenium) dentro de DDEV y reporta cobertura. Si un test no puede pasar por una causa externa (p. ej. una dependencia contrib sin soporte D11), se documenta explícitamente en vez de silenciarlo.

### 6. Obtén el parche — prueba en local ahora, contribuye después

```text
/drupilot-patch web/modules/custom/my_module
```

Escribe `MODULE-port-to-drupal-11.patch` junto al módulo — offline, sin push, sin cuenta de Drupal.org. Aplícalo en otra copia con `git apply`. El parche se calcula contra el **punto de bifurcación** de tu rama — su upstream si lo tiene; si no, el más cercano entre `origin/HEAD`, las demás ramas remotas y la etiqueta más próxima (p. ej. una rama local creada desde una etiqueta de release) — así que contiene exactamente el port, esté confirmado o no; pasa `--base` para elegir. Se mantiene fuera de `git status` mediante el `.git/info/exclude` local del repo. ¿Quieres adjuntarlo a un issue y validarlo allí antes de abrir un Merge Request? Pasa el id del issue para un parche con nombre de issue-comment:

```text
/drupilot-patch web/modules/custom/my_module 3456789
```

Esto está totalmente **desacoplado de contribuir**: el Merge Request upstream (que hace rebase y verifica en duro que el parche aplica sobre `origin/BASE`) sigue siendo un paso aparte y opt-in que ejecutas con `/drupilot-contribute` cuando estés listo.

### 7. Contribuir el arreglo de vuelta a Drupal.org

Semi-automático (recomendado — confirma cada push / MR):

```text
/drupilot-contribute web/contrib/some_module 3456789
```

Totalmente automático (requiere SSH o un PAT configurado):

```bash
export DRUPILOT_CONTRIB_MODE=auto
export DRUPILOT_GITLAB_PAT=glpat-xxxxxxxx   # nunca se almacena; se lee en runtime
```
```text
/drupilot-contribute web/contrib/some_module 3456789
```

Cuando el issue aún no existe, genera el **resumen del issue** (la plantilla estándar de Drupal.org — para un portado que preserva el comportamiento, solo las secciones que aplican: Problem/Motivation, Proposed resolution, Remaining tasks) y los **valores recomendados de los campos** (Title, Category `Task`, Priority `Normal`, Version derivada de la rama base, Component `Code`, Assigned a ti), ya que el issue solo puede crearse en la web. Después crea el issue fork, la rama y el commit (en el formato correcto, detectando la convención del proyecto), hace push, abre el Merge Request — con un breve **comentario** generado como descripción — vía la API de GitLab, **degradando con gracia** a una URL de MR de un clic si la API está bloqueada. **Siempre escribe un `.patch`** (`MODULE-port-to-drupal-11-ISSUEID-COMMENT.patch`) y **verifica que aplica limpio** sobre la versión a la que se refiere (descartando un parche que no aplica, para que nunca entregues uno roto) para adjuntarlo al issue junto al MR y el comentario. Te recuerda que **el crédito lo asignan los maintainers** mediante el Contribution Record del issue, y nunca expone tu PAT.

---

## Cómo funciona (arquitectura)

- **Comandos** (`commands/*.md`) son los puntos de entrada. Cada uno valida sus propios requisitos vía el motor de preflight antes de hacer nada.
- **Skills** (`skills/*/SKILL.md`) llevan el conocimiento operativo reutilizable (entorno DDEV, estudio de viabilidad, portabilidad mínima, refactor completo, adaptación de tests, ajuste del target de PHP, contribución a Drupal).
- **Subagentes** (`agents/*.md`) son los especialistas a los que delegan los comandos: `drupal-port-orchestrator`, `drupal-viability-analyst`, `drupal-test-engineer`, `drupal-contrib-publisher`.
- **Hooks** (`hooks/hooks.json`):
  - `SessionStart` → un detector de entorno ligero que resume tu target de PHP y la disponibilidad (siléncialo con `DRUPILOT_SESSION_CONTEXT=off`).
  - `PostToolUse` (Write|Edit) → `phpcbf` + `phpcs` incremental sobre los ficheros Drupal editados; **consciente de fase** (la Fase 1 saca solo errores de compatibilidad) y controlable con `DRUPILOT_POST_EDIT_LINT` (`autofix`/`report`/`off`), y te avisa cuando modifica un fichero.
  - `PreToolUse` (Bash) → pide confirmación antes de cualquier `git push` / acción de MR hacia el exterior en modo `semi`, y **siempre** en una ejecución autónoma (que nunca debe empujar por su cuenta).
- **Scripts** (`scripts/`) son una librería de shell robusta e idempotente: un `lib/common.sh` compartido, el motor de requisitos `env/preflight.sh`, y los wrappers de `analysis/`, `tests/` y `contrib/` que invocan las skills y los comandos.
- **Plantillas** (`templates/`) son configuraciones parametrizadas (`rector.php`, `phpstan.neon`, `phpcs.xml.dist`, config de DDEV + entorno de tests, plantillas de informe) afinadas por el target de PHP.

Consulta **[FLOW_es.md](FLOW_es.md)** para un diagrama visual de todo el flujo — qué herramienta actúa en cada paso, dónde interviene la IA y las dos fases de la portabilidad.

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
- **Nada marcado como incierto se asume** (soporte de PHP 8.5, el hostname del webdriver, la disponibilidad de imagen DDEV): se detecta en runtime y se degrada con gracia.
- **Verificación final** antes de dar un módulo por terminado: un `info.yml` compatible, `phpstan` sin deprecaciones al nivel objetivo, un `phpcs Drupal,DrupalPractice` limpio, `check-port-safety.sh` y `scan-signature-changes.sh` sin hallazgos de error y la suite de tests aplicable en verde.
- **No se confía ciegamente en Rector.** El `rector.php` generado omite las reglas de modernización de PHP que rompieron ports reales (callbacks de la Form API convertidos en closures, `#[\Override]` decidido solo contra el core del sandbox, propiedades `readonly`, casts `(string)`); ninguna es necesaria para la compatibilidad con Drupal 11.

---

## Resolución de problemas

- **Un comando dice que falta un requisito duro.** Ejecuta `/drupilot-doctor` — muestra exactamente qué falta, la versión detectada vs. la requerida, y el comando de instalación para tu plataforma.
- **Docker está instalado pero los comandos siguen fallando.** El daemon debe estar corriendo (`sudo systemctl start docker` en Linux, o lanzar Docker Desktop). `drupilot` comprueba el daemon, no solo el binario.
- **`run-phpunit.sh` termina con código 2 y "PHPUnit is not installed" (preservación `not-verified-blocked`).** La raíz de Drupal no tiene `vendor/bin/phpunit`: `drupal/recommended-project` no lo incluye. Instala `drupal/core-dev` ajustado a tu core — el script muestra el comando exacto, p. ej. `ddev composer require --dev "drupal/core-dev:~11.4.8" -W` — y vuelve a ejecutarlo. Los entornos preparados con drupilot 0.8.4 o anterior nunca lo instalaron.
- **Los tests FunctionalJavascript se omiten.** Instala el add-on de Selenium: `ddev add-on get ddev/ddev-selenium-standalone-chrome && ddev restart`.
- **Aparece una carpeta de symlinks espuria `web/modules/custom/<proyecto>/` tras `ddev restart`.** La provoca el hook `symlink-project` de `ddev-drupal-contrib` en el layout recommended-project; `ddev-add-ons.sh` lo desactiva en `.ddev/config.contrib.yaml`. Ese fichero es `#ddev-generated`, así que un `ddev add-on get ddev/ddev-drupal-contrib` posterior restaura el hook — vuelve a ejecutar `/drupilot-setup` (o `ddev-add-ons.sh --contrib`) después.
- **La API de GitLab está bloqueada.** Es lo esperado — la API de drupalcode está restringida por defecto. `drupilot` degrada a una URL de MR de un clic; solo ábrela para crear el MR.
- **El plugin no carga.** Ejecuta `claude plugin validate /ruta/a/drupilot` para revisar el manifiesto y el frontmatter de los componentes.
- **`phpcs` en la raíz de Drupal falla con "Ruleset … is not valid … Comment must not contain '--'", o PHPStan muestra "The drupal_root parameter is deprecated".** Tus `phpcs.xml.dist` / `phpstan.neon` los generó drupilot 0.8.4 o anterior. Regenéralos (las copias antiguas se guardan en `.drupilot/backups/`): `bash "$CLAUDE_PLUGIN_ROOT/scripts/env/render-templates.sh" --root <raiz_drupal> --subject-path web/modules/custom/<nombre> --only phpstan,phpcs --force`. Sin `--force` solo muestra el diff.
- **Rector falla con "[ERROR] Could not detect twig set." (o `MissingPrivatePropertyException … RichParser`), o `run-rector.sh` / `install-toolchain.sh` terminan con código 3.** La toolchain instalada es una combinación incompatible: `palantirnet/drupal-rector` 0.21 necesita `rector/rector` < 2.6.2, y `rector/rector` 2.5.x necesita PHPStan 2.2.2. drupilot 0.8.4 y anteriores resolvían los rangos de nuevo y podían instalar justo eso, e informaban del fallo como «0 files would change». Reinstala el conjunto conocido-bueno (también refresca el lock): `bash "$CLAUDE_PLUGIN_ROOT/scripts/env/install-toolchain.sh" --dir <drupal_root> --source reference`. Ahora `run-rector.sh` informa de un fallo como `status: "error"` (código 3), nunca como un resultado. Si la toolchain ya coincide con el conjunto conocido-bueno, el problema es la configuración de Rector: regenera `rector.php` con `render-templates.sh --only rector --force`.
- **`run-rector.sh --digests` termina con código 4 (`status: "partial"`, `digests_status: "error"`), p. ej. `[ERROR] Expected an existing class name. Got: "…Rector"`.** Solo falló la pasada de digests generada por IA, normalmente por un fichero de regla roto en un commit upstream de `drupal-digests`. El resultado de la pasada oficial sigue siendo válido y la toolchain está bien, así que no la reinstales. Fija un commit de digests conocido-bueno (`--digests-ref <sha>` o `DRUPILOT_DIGESTS_REF=<sha>`) u omite la capa (`DRUPILOT_USE_DIGESTS_RULES=false`). Un SHA de digests solo se congela en el lockfile cuando su pasada termina con normalidad, así que nunca se fija un commit roto.
- **Rector convirtió callbacks de la Form API `[$this, 'method']` en `$this->method(...)`, o añadió `#[\Override]`, `readonly` o casts `(string)`.** Tu `rector.php` es anterior a la lista de reglas omitidas. `run-rector.sh` regenera en su siguiente ejecución un `rector.php` escrito por una plantilla de drupilot anterior (la copia antigua va a `.drupilot/backups/`); uno escrito a mano se respeta y solo se avisa — añade las exclusiones de `templates/rector.php.tmpl`. Después revierte los cambios convertidos; `check-port-safety.sh` los lista.
- **`check-port-safety.sh` termina con código 3.** Encontró hallazgos de error — p. ej. un plugin cuyo `create()` perdió `implements ContainerFactoryPluginInterface` (`QueueWorkerBase`, `BlockBase`, `FilterBase`, `ActionBase` y `ConditionPluginBase` no la implementan), `new self(` en `create()`, un closure bajo `#submit`/`#ajax`/..., o una propiedad `readonly`/`private` en un formulario o plugin. Cada línea indica el fichero, la línea, la corrección y si lo introdujo el port; corrígelos y vuelve a ejecutarlo. Si el port ya está commiteado, pasa `--base <ref previa al port>` para que la atribución sea correcta.
- **`scan-signature-changes.sh` termina con código 3.** El módulo choca con un cambio de firma de core dentro del rango de core que declara — p. ej. `parent::__construct($config_factory)` en una subclase de `ConfigFormBase` (Drupal 11 exige también `TypedConfigManagerInterface`: pasa `$container->get('config.typed')`, que los cores 10.x antiguos simplemente ignoran), un `getOriginal()` de entidad sin `: ?static` (fatal en 11.2+), o un `hook_entity_operation()` que exige `$cacheability` mientras sigues declarando cores anteriores a 11.3 (déjalo como `?CacheableMetadata $cacheability = NULL`). Cada hallazgo incluye la corrección y la forma compatible con Drupal 10; la severidad sigue al suelo declarado (`^10 || ^11` → 10.0), y `--core-floor X.Y` evalúa con otro.
- **PHPStan sigue listando `user_load_by_name()` (o `text_summary()`, `check_markup()`) tras el port.** Es una deprecación *blanda*: deprecada en 11.4.0 y eliminada en 13.0.0, así que funciona en todos los cores de Drupal 11, y el valor por defecto `DRUPILOT_SOFT_DEPRECATIONS=report` la deja a propósito y la lista en `port-report.md`. Ponlo en `fix` (o ejecuta `/drupilot-refactor`) para reemplazarla; drupilot mantiene entonces funcionando el suelo de core declarado — p. ej. el servicio `TextSummary` solo existe desde 11.4, así que con `^10 || ^11` pasa por `DeprecationHelper::backwardsCompatibleCall()`. Una *dura* (eliminada en 11.0, p. ej. `user_roles()`, que PHPStan reporta como "Function user_roles not found.") siempre bloquea la Fase 1.
- **`run-phpstan.sh` termina con código 3.** PHPStan falló o no pudo analizar (configuración inválida, ruta inexistente, error fatal), así que no hay veredicto; la causa se muestra en stderr (y en `drupilot.crash` con `--json`). Corrígela y vuelve a ejecutarlo: no es un recuento de hallazgos.

---

## Desarrollo de drupilot

Ejecuta la puerta de desarrollo antes de cada commit sobre el propio plugin:

```bash
bash scripts/dev/check.sh          # informe legible; exit 0 ok / 1 alguna puerta falló
bash scripts/dev/check.sh --json   # resumen por puerta legible por máquina
```

Valida el manifiesto del plugin, comprueba la sintaxis y pasa `shellcheck` por todos los scripts, verifica los bits de ejecución, rechaza construcciones exclusivas de bash 4 / GNU (`${x,,}`, `declare -A`, `sed -i`, `readlink -f`, ... — los scripts deben funcionar con el bash 3.2 de serie de macOS), rechaza variables especiales de bash usadas como variables normales (`GROUPS`, `RANDOM`, `SECONDS`, `UID`, ... — bash ignora en silencio esas asignaciones), rechaza literales `<placeholder>` dentro de las líneas `` !`...` `` que se ejecutan al cargar commands/skills/agents, comprueba que las plantillas XML renderizadas estén bien formadas y valida todos los ficheros JSON. Las herramientas opcionales (`claude`, `shellcheck`, `xmllint`) se omiten si no están (`--ci` las hace obligatorias). Consulta `--help` para `--only`/`--skip`/`--allow-known`.

---

## Licencia

MIT. Ten en cuenta que las reglas opcionales de `dbuytaert/drupal-digests` son de terceros, sin licencia, y nunca se empaquetan con este plugin — se descargan en runtime a una caché local.
