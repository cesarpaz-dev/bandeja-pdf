# Desarrollo de Bandeja PDF

Este repositorio publica el código fuente de un prototipo para Mac con Apple Silicon. Compilar los ejecutables y ejecutar las pruebas del núcleo no instala una impresora. El empaquetado de la app y su instalación local son pasos separados.

Los comandos de esta guía se ejecutan desde la raíz del repositorio.

## Requisitos

- Mac con Apple Silicon. El paquete declara macOS 15 como versión mínima; la compatibilidad debe comprobarse en cada versión del sistema que se anuncie.
- Herramientas Swift y SDK de macOS. La configuración comprobada usa Apple Swift 6.4.2 con Command Line Tools. `Package.swift` declara `swift-tools-version: 5.9`; esto no equivale a una prueba con todos los compiladores desde Swift 5.9.
- Para `swift test`, una instalación de herramientas que incluya XCTest. Se proporciona un ejecutor alternativo para entornos con Command Line Tools sin XCTest.
- Para la prueba PostScript, un ejecutable Ghostscript funcional y sus recursos. Se comprobó Ghostscript 10.08.0. No es necesario para compilar los fuentes Swift, pero la suite completa exige esta dependencia y falla si falta.
- Python 3.12, comprobado para las herramientas de integración e inspección. Python no forma parte del funcionamiento de la app nativa.

La documentación oficial explica cómo obtener [Swift para macOS](https://www.swift.org/install/macos/) y las [Command Line Tools de Apple](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools). Las herramientas y sus licencias se preparan por separado; los scripts del proyecto no las instalan ni aceptan licencias automáticamente.

## Compilar los fuentes

```sh
swift build --package-path native --configuration release --arch arm64
swift build --package-path native --configuration release --arch arm64 --show-bin-path
```

El segundo comando muestra el directorio de los ejecutables `BandejaPDF`, `BandejaAgent` y `BandejaCLI`. Este paso no genera por sí solo una app instalada. No requiere Ghostscript, Python ni paquetes Swift externos: se utilizan los frameworks de macOS y SQLite del sistema.

## Probar el núcleo sin instalar

Las pruebas crean documentos sintéticos y almacenes temporales. No se conectan al agente instalado, no envían trabajos de impresión y no modifican colas. Comprueban capacidad 10 + 10, avisos, persistencia, operaciones, deshacer, conservación de texto, exportación intacta y conversión PostScript.

Indica un Ghostscript ya preparado mediante una ruta absoluta al ejecutable:

```sh
BANDEJA_TEST_GS="/ruta/al/runtime/bin/gs" \
  swift test --package-path native
```

Si XCTest no está disponible, usa los mismos casos mediante el ejecutor independiente:

```sh
BANDEJA_TEST_GS="/ruta/al/runtime/bin/gs" \
  sh native/Tests/BandejaCoreTests/run-standalone.sh
```

Sin `BANDEJA_TEST_GS`, la suite busca `native/build/runtime/bin/gs`. La prueba PostScript no se omite silenciosamente si el conversor falta. `BANDEJA_TEST_GS` apunta al ejecutable; la variable de empaquetado `BPDF_GS_RUNTIME`, descrita después, apunta al directorio del runtime.

El ejecutor independiente consulta `swift build --show-bin-path` y admite tanto los productos agregados de Swift Build/Xcode como el directorio `Modules` y los objetos por fuente de SwiftPM nativo. Se comprobaron los 11 casos en ambos layouts. El JSON de la última ejecución queda en `native/Tests/BandejaCoreTests/.standalone/results.json`; un fallo devuelve un estado de salida distinto de cero.

## Preparar las herramientas Python

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
```

`requirements-dev.txt` fija las dependencias directas comprobadas: pypdf 6.10.0, ReportLab 4.4.9, pypdfium2 5.14.0 y Pillow 12.3.0. La instalación descarga dependencias en el entorno virtual; no instala una impresora. No subas `.venv` al repositorio.

`smoke.py` utiliza ReportLab para crear PDFs sintéticos y pypdf para comprobarlos. `inspect-receipt.py` añade PDFium y Pillow para verificar y renderizar copias de documentos recibidos.

## Empaquetar una app de desarrollo

**Prerrequisito pendiente de automatizar:** disponer de un runtime privado de Ghostscript para Apple Silicon. Esta publicación no incluye ese runtime ni un generador para prepararlo. Por ello, un clon limpio permite compilar los fuentes, pero todavía no ofrece un proceso completo de empaquetado a partir de cero.

El directorio indicado debe contener `bin/gs`, sus bibliotecas no pertenecientes al sistema y los recursos de Ghostscript necesarios para funcionar después de copiarlo a otra ubicación. Habitualmente incluye `lib/` y `share/ghostscript/`. Copiar únicamente `gs` o señalar un prefijo completo de Homebrew no sustituye la preparación y verificación del runtime.

```sh
BPDF_GS_RUNTIME="/ruta/al/runtime" bash native/scripts/build.sh
```

El script compila para arm64, copia el runtime completo y los recursos propios, firma ad hoc y verifica el bundle y el PPD. El resultado queda en `native/build/Bandeja PDF.app`. No instala ni abre la app y no crea una cola. La firma ad hoc sirve para desarrollo local; no es una firma Developer ID ni notarización.

Los avisos, licencias y fuentes correspondientes del runtime deben resolverse antes de distribuirlo. Véase [dependencias y licencias](../THIRD_PARTY_NOTICES.md). No publiques el bundle de desarrollo como una versión de distribución.

## Instalar la cola local de desarrollo

Este paso modifica la cuenta y el sistema de impresión. Requiere una sesión gráfica y permisos para administrar impresoras. Ejecútalo desde la cuenta que utilizará la bandeja, **sin anteponer `sudo`**:

```sh
bash native/scripts/install-local.sh
```

Instala la app en `~/Applications/Bandeja PDF.app`, registra `~/Library/LaunchAgents/local.bandejapdf.agent.plist` y crea la cola `bandeja_pdf`, cuyo receptor utiliza el puerto local 18633. Los datos se guardan en `~/Library/Application Support/BandejaPDF`.

El instalador rechaza una app, registro o cola con el mismo nombre ya existentes y comprueba que el puerto esté libre. No configura una impresora predeterminada. No incorpora un flujo de actualización ni un desinstalador de distribución. Si falta autorización para administrar impresoras, revisa ese requisito de la cuenta antes de volver a ejecutar el instalador; no cambies de usuario mediante `sudo` para eludirlo.

La instalación utiliza un LaunchAgent de desarrollo. La integración definitiva con SMAppService, el aislamiento entre cuentas locales y el instalador de distribución siguen pendientes. El puerto IPP está limitado a loopback, pero este prototipo no autentica a otras cuentas locales.

## Prueba de integración con la cola instalada

Esta prueba sí agrega documentos a la bandeja. Ejecuta primero las pruebas aisladas y deja la nueva cola sin actividad concurrente:

```sh
.venv/bin/python native/scripts/smoke.py --submit --require-ps
```

El script valida el destino `bandeja_pdf` en loopback y el puerto 18633, comprueba capacidad libre y envía como máximo un PDF y un PostScript sintéticos. Después exporta copias y verifica texto, geometría y copia idéntica del PDF sin cambios. No instala, reconfigura, vacía ni cancela trabajos; tampoco reintenta envíos automáticamente.

Los resultados quedan en `native/build/smoke/`. El informe incluye los identificadores de los documentos creados para retirarlos después de revisarlos. Un resultado fallido o sin confirmar exige inspeccionar la cola y la bandeja antes de repetir el envío: el fallo del cliente no demuestra que el documento no haya llegado.

## Inspección manual y límites

Para verificar un documento ya recibido y exportar una copia local:

```sh
.venv/bin/python native/scripts/inspect-receipt.py \
  --id "IDENTIFICADOR_DEL_DOCUMENTO" \
  --output native/build/inspection \
  --token "TEXTO_ESPERADO"
```

Esta herramienta consulta el agente instalado, exporta una copia y genera imágenes y un informe; no elimina el documento. Su directorio de salida puede contener información privada. No lo publiques ni lo adjuntes a incidencias sin revisar y anonimizar su contenido.

Las pruebas automáticas no sustituyen comprobar la interfaz, el arranque tras reiniciar el Mac, bloqueo y desbloqueo de sesión, recuperación abrupta, impresión física y un Mac limpio. Tampoco acreditan conservación de formularios y marcadores durante composición: la versión actual bloquea esas operaciones y permite exportar sin cambios.

La app conserva el texto que existe en el origen. Si una aplicación envía letras como imágenes o contornos, muestra «Sin texto seleccionable»; no reconstruye caracteres ni aplica OCR. Los cambios visuales, el zoom y las miniaturas no deben convertirse en la fuente del PDF exportado.
