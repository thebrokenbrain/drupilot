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
- [Modo autónomo (manos fuera)](#modo-autónomo-manos-fuera)
- [Configuración](#configuración)
- [Casos de uso](#casos-de-uso)
- [Cómo funciona (arquitectura)](#cómo-funciona-arquitectura)
- [La capa complementaria drupal-digests](#la-capa-complementaria-drupal-digests)
- [Seguridad y convenciones](#seguridad-y-convenciones)
- [Resolución de problemas](#resolución-de-problemas)
- [Licencia](#licencia)

---

## Qué hace

- **Estudio de viabilidad** — un análisis estático no destructivo (Rector en dry-run, PHPStan, PHPCS, y opcionalmente Upgrade Status) que estima qué parte del trabajo es auto-corregible vs. manual, clasifica las rupturas duras (Twig 3, CKEditor 5, jQuery UI, Symfony 7), revisa el `info.yml` y el soporte D11 de las dependencias contrib, recomienda un **target de compatibilidad de core** (`^11` vs `^10 || ^11`, el `require.php` que implica y un veredicto SemVer de subida de versión), y produce un informe markdown más un **plan de portabilidad por etapas** con un veredicto de esfuerzo S/M/L/XL.
- **Portabilidad mínima (Fase 1)** — el conjunto de cambios más pequeño para que el módulo/tema funcione en Drupal 11 **respetando la funcionalidad original**. Motor: `palantirnet/drupal-rector`, una capa opcional de reglas IA (`dbuytaert/drupal-digests`) y ajustes manuales puntuales.
- **Refactor completo (Fase 2, opt-in)** — una reescritura a las mejores prácticas modernas de Drupal 11: atributos PHP 8 para plugins, inyección de dependencias, tipados estrictos, cero deprecaciones, `Drupal` + `DrupalPractice` limpios y suite de tests en verde.
- **Tests** — descubre, adapta y ejecuta la suite PHPUnit completa (Unit / Kernel / Functional / FunctionalJavascript) dentro de DDEV (con Selenium para JS), iterando hasta verde y reportando cobertura. Los fallos **nunca** se silencian.
- **Contribución** — prepara y (opcionalmente) publica el resultado a Drupal.org mediante el flujo moderno issue-fork + Merge Request, o un patch legacy, en modo **semi-automático** (confirma cada acción externa) o **totalmente automático**. Siempre se genera un `.patch` junto al MR para adjuntarlo al issue.
- **Patches** — toda portabilidad escribe además un `.patch` local (`MODULE-port-to-drupal-11.patch`) para que puedas revisar el cambio, aplicarlo en otro sitio o probarlo en local antes de contribuir — sin necesidad de cuenta de Drupal.org.

El target de PHP por defecto es **8.3** y es totalmente configurable; todo (sets de Rector, nivel de PHPStan, sniffs de PHPCS, `php_version` de DDEV) deriva de un único ajuste.

---

## Requisitos

`drupilot` valida solo lo que necesita cada operación, así que no necesitas Docker solo para ejecutar un análisis estático. Ejecuta `/drupilot-doctor` en cualquier momento para una tabla de estado por plataforma e instalación asistida.

| Operación | Requisitos duros | Opcionales / blandos |
| --- | --- | --- |
| **Análisis** (`assess`, `port` estático) | `git`, `jq`, y `composer` o `php` ≥ target | — |
| **Entorno y tests** (`setup`, `test`) | **Docker** (daemon activo) + **DDEV** (una versión con soporte Drupal 11) | add-on Selenium (para FunctionalJavascript), espacio en disco |
| **Contribución** (Drupal.org) | `git`, cuenta drupal.org + acceso a GitLab, y una **clave SSH** o un **PAT** | `glab`/`curl` para la API de GitLab (degradable) |

DDEV provee el entorno Drupal completo (web + base de datos + chromedriver) sobre Docker — **no necesitas montar un stack LAMP tú mismo**.

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

---

## Comandos

| Comando | Qué hace |
| --- | --- |
| `/drupilot [sujeto] [full\|auto]` | **Router / flujo guiado.** Detecta el estado actual (entorno, último assess, fase) y recomienda el siguiente paso. `full` ejecuta todo el flujo con confirmaciones; `auto` lo ejecuta **sin intervención** (ver más abajo). |
| `/drupilot-doctor [install]` | **Verificación de requisitos.** Tabla de estado por plataforma (Docker + daemon, DDEV, git, composer/php, jq, SSH/PAT) con instrucciones de instalación e instalación asistida opcional (con confirmación). |
| `/drupilot-setup` | Levanta un sitio **Drupal 11 con DDEV**, instala los add-ons (`ddev-drupal-contrib`, Selenium) y el toolchain de desarrollo de Composer, y escribe `rector.php` / `phpstan.neon` / `phpcs.xml.dist` / entorno de tests desde plantillas. Idempotente. |
| `/drupilot-assess [sujeto]` | Produce el **informe de viabilidad** + plan por etapas con veredicto S/M/L/XL. |
| `/drupilot-port [sujeto]` | **Portabilidad mínima (Fase 1).** Rector oficial + (opcional) reglas digests filtradas por target + ajustes ad-hoc + cambios manuales mínimos; deja el código compilando sin deprecaciones bloqueantes. |
| `/drupilot-refactor [sujeto]` | **Refactor completo (Fase 2)** (opt-in): el "estilo Drupal 11", PHPStan nivel 5–6, PHPCS limpio. |
| `/drupilot-test [sujeto]` | Descubre, adapta y ejecuta **toda** la suite de tests en DDEV (Selenium para JS); itera hasta verde; reporta cobertura. |
| `/drupilot-contribute [sujeto] [issue]` | Publica a **Drupal.org**: issue fork + Merge Request (o patch legacy), en modo semi o auto. Solo invocable por el usuario; nunca expone el PAT. |
| `/drupilot-status` | Resumen de solo lectura: entorno, target de PHP, fase actual, último assess, estado de tests y siguiente paso sugerido. |

---

## Filosofía de portabilidad en dos fases

1. **Fase 1 — Compatibilidad mínima (por defecto).** Los cambios mínimos para que el módulo/tema funcione en Drupal 11 respetando la funcionalidad original y **sin colisionar** con lo que Drupal 11 ya ofrece. Motor: `drupal-rector` + ajustes manuales puntuales. Sin cambios de arquitectura.
2. **Fase 2 — Refactor "estilo Drupal 11" (opt-in).** Una reescritura a las mejores prácticas modernas: atributos PHP 8 para plugins, inyección de dependencias, tipado estricto, cero deprecaciones, cero errores de PHPStan al nivel objetivo, cumplimiento total de `Drupal` + `DrupalPractice` y tests completos en verde.

Un **estudio de viabilidad** siempre se ejecuta primero como gate de decisión. Si el refactor es desproporcionado (umbral configurable), `drupilot` no se niega — igual entrega un plan de portabilidad por etapas que respeta la funcionalidad original, y te deja la decisión.

**Cómo se verifica que «se respeta la funcionalidad original».** Que la suite de tests adaptada siga en **verde es el gate de preservación** en ambas fases — ese verde es la prueba de que el comportamiento se preserva. Las adaptaciones de los tests solo cambian la *forma* del test (API de PHPUnit/Drupal), nunca *lo que verifica*; una regresión de comportamiento se arregla en el código, nunca relajando un test. Si el módulo **no tiene tests**, `drupilot` informa de que la preservación **no está verificada** y recomienda añadirlos — no los inventa.

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

Los valores por defecto están en `config/defaults.json`. **Cada clave `DRUPILOT_*` puede sobreescribirse con una variable de entorno del mismo nombre** (la variable de entorno siempre gana).

| Variable | Por defecto | Efecto |
| --- | --- | --- |
| `DRUPILOT_PHP_TARGET` | `8.3` | Versión de PHP destino (controla Rector / PHPStan / PHPCS / DDEV). |
| `DRUPILOT_DRUPAL_TARGET` | `^11` | Rango de core destino. |
| `DRUPILOT_CORE_TARGET_STRATEGY` | `auto` | Decisión de compatibilidad de core: `auto` (mantiene `^10 \|\| ^11` mientras sea retrocompatible, pasa a `^11` ante una ruptura BC / refactor), `d11-only` o `keep-d10`. Mantener D10 declara además composer `require.php: ">=<target>"`, y la elección produce un veredicto SemVer de subida de versión. |
| `DRUPILOT_KEEP_D10` | _(legacy)_ | Override booleano legacy de la estrategia (`true` → mantener D10, `false` → solo D11). Solo se respeta si se exporta; prefiere `DRUPILOT_CORE_TARGET_STRATEGY`. |
| `DRUPILOT_CODER_CONSTRAINT` | `^8.3` | Rama de `drupal/coder` (PHPCS 3.x vs 4.x). |
| `DRUPILOT_PHPSTAN_LEVEL` | `2` | Nivel base de PHPStan (detección de deprecaciones). |
| `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` | `6` | Nivel de PHPStan usado en la fase de refactor. |
| `DRUPILOT_VIABILITY_THRESHOLD` | `medium` | Umbral para el aviso de "refactor grande". |
| `DRUPILOT_CONTRIB_MODE` | `semi` | `semi` (confirma acciones externas) o `auto`. |
| `DRUPILOT_USE_DIGESTS_RULES` | `true` | Usar la capa complementaria `drupal-digests` tras el Rector oficial. |
| `DRUPILOT_DIGESTS_REF` | `main` | Commit/tag del repo `drupal-digests`, para reproducibilidad. |
| `DRUPILOT_GENERATE_RULES` | `ask` | Generar reglas Rector ad-hoc para deprecaciones no cubiertas: `ask` / `auto` / `off`. |
| `DRUPILOT_AUTONOMOUS` | `false` | Modo manos fuera (equivale a la palabra de modo `auto`): setup→assess→port→refactor→test sin intervención, escribe el patch local, **nunca** contribuye. Ver [Modo autónomo](#modo-autónomo-manos-fuera). |
| `DRUPILOT_DETERMINISTIC` | `true` | Reproducibilidad (activado por defecto): congela el Drupal core, la toolchain de desarrollo, el SHA de digests y los add-ons de DDEV resueltos en un `drupilot-lock.json` por proyecto y los reutiliza en ejecuciones posteriores. Ponlo a `false` para resolver todo de nuevo cada vez y refrescar el lock. Ver [Determinismo](#determinismo-reproducible-por-defecto). |

Otras variables de entorno útiles: `DRUPILOT_GITLAB_PAT` (tu Personal Access Token de GitLab, leído solo en runtime, nunca persistido), `DRUPILOT_ASSUME_YES=1` (saltar confirmaciones en ejecuciones no interactivas), `NO_COLOR=1`.

Ejemplo — apuntar a PHP 8.4 y abandonar el soporte de Drupal 10 durante una sesión:

```bash
export DRUPILOT_PHP_TARGET=8.4
export DRUPILOT_CORE_TARGET_STRATEGY=d11-only   # solo ^11 (abandona Drupal 10)
```

---

## Determinismo (reproducible por defecto)

Portar el mismo módulo dos veces debería dar el mismo resultado. drupilot es **determinista por defecto** (`DRUPILOT_DETERMINISTIC=true`): la primera vez que resuelve las partes móviles de un port las **congela** en un `drupilot-lock.json` por proyecto (guardado en el directorio de estado de drupilot, no en tu árbol de proyecto) y las **reutiliza** en ejecuciones posteriores:

- la versión exacta de **Drupal core** y las versiones de la **toolchain de desarrollo** (`drupal-rector`, PHPStan + extensiones, `coder`/PHPCS, Drush) leídas del `composer.lock` generado;
- el **commit (SHA) de digests** al que resolvió la rama `main` — así la capa de reglas generadas por IA queda fija para el proyecto aunque su ref por defecto siga siendo `main`;
- las versiones de los **add-ons de DDEV** instalados.

Funciona como un `composer.lock`: los rangos de versión en `config/defaults.json` siguen siendo flexibles, pero el lock fija exactamente lo que se usó. `scripts/env/lock-sync.sh` lo captura/actualiza (`ddev-up.sh` y `ddev-add-ons.sh` lo llaman automáticamente).

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

### 6. Contribuir el arreglo de vuelta a Drupal.org

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

Crea el issue fork, la rama y el commit (en el formato correcto, detectando la convención del proyecto), hace push, abre el Merge Request vía la API de GitLab — **degradando con gracia** a una URL de MR de un clic si la API está bloqueada — y **además escribe un `.patch`** (`MODULE-port-to-drupal-11-ISSUEID-COMMENT.patch`) para adjuntarlo al issue junto al MR. Te recuerda que **el crédito lo asignan los maintainers** mediante el Contribution Record del issue, y nunca expone tu PAT.

---

## Cómo funciona (arquitectura)

- **Comandos** (`commands/*.md`) son los puntos de entrada. Cada uno valida sus propios requisitos vía el motor de preflight antes de hacer nada.
- **Skills** (`skills/*/SKILL.md`) llevan el conocimiento operativo reutilizable (entorno DDEV, estudio de viabilidad, portabilidad mínima, refactor completo, adaptación de tests, ajuste del target de PHP, contribución a Drupal).
- **Subagentes** (`agents/*.md`) son los especialistas a los que delegan los comandos: `drupal-port-orchestrator`, `drupal-viability-analyst`, `drupal-test-engineer`, `drupal-contrib-publisher`.
- **Hooks** (`hooks/hooks.json`):
  - `SessionStart` → un detector de entorno ligero que resume tu target de PHP y la disponibilidad.
  - `PostToolUse` (Write|Edit) → `phpcbf` + `phpcs` incremental sobre los ficheros Drupal editados.
  - `PreToolUse` (Bash) → en modo `semi`, pide confirmación antes de cualquier `git push` / acción de MR hacia el exterior.
- **Scripts** (`scripts/`) son una librería de shell robusta e idempotente: un `lib/common.sh` compartido, el motor de requisitos `env/preflight.sh`, y los wrappers de `analysis/`, `tests/` y `contrib/` que invocan las skills y los comandos.
- **Plantillas** (`templates/`) son configuraciones parametrizadas (`rector.php`, `phpstan.neon`, `phpcs.xml.dist`, config de DDEV + entorno de tests, plantillas de informe) afinadas por el target de PHP.

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
- **Verificación final** antes de dar un módulo por terminado: un `info.yml` compatible, `phpstan` sin deprecaciones al nivel objetivo, un `phpcs Drupal,DrupalPractice` limpio y la suite de tests aplicable en verde.

---

## Resolución de problemas

- **Un comando dice que falta un requisito duro.** Ejecuta `/drupilot-doctor` — muestra exactamente qué falta, la versión detectada vs. la requerida, y el comando de instalación para tu plataforma.
- **Docker está instalado pero los comandos siguen fallando.** El daemon debe estar corriendo (`sudo systemctl start docker` en Linux, o lanzar Docker Desktop). `drupilot` comprueba el daemon, no solo el binario.
- **Los tests FunctionalJavascript se omiten.** Instala el add-on de Selenium: `ddev add-on get ddev/ddev-selenium-standalone-chrome && ddev restart`.
- **La API de GitLab está bloqueada.** Es lo esperado — la API de drupalcode está restringida por defecto. `drupilot` degrada a una URL de MR de un clic; solo ábrela para crear el MR.
- **El plugin no carga.** Ejecuta `claude plugin validate /ruta/a/drupilot` para revisar el manifiesto y el frontmatter de los componentes.

---

## Licencia

MIT. Ten en cuenta que las reglas opcionales de `dbuytaert/drupal-digests` son de terceros, sin licencia, y nunca se empaquetan con este plugin — se descargan en runtime a una caché local.
