# Dependencias y licencias

El código propio de Bandeja PDF se publica bajo **GNU Affero General Public License, versión 3 únicamente (`AGPL-3.0-only`)**. El texto aplicable está en [LICENSE](LICENSE). Esa elección no cambia las licencias de componentes de terceros ni sustituye sus requisitos de redistribución.

Esta publicación contiene fuentes, configuración propia y herramientas de prueba. No incluye el runtime de Ghostscript, sus bibliotecas o fuentes, los frameworks de Apple, los paquetes Python instalados, ni una aplicación binaria lista para distribuir. Las dependencias externas se obtienen por separado.

## Componentes utilizados por la aplicación

| Componente | Uso y procedencia | Licencia o referencia |
| --- | --- | --- |
| AppKit, PDFKit, Foundation, CryptoKit y otros frameworks de macOS | APIs del SDK y bibliotecas proporcionadas por Apple; no se copian sus implementaciones al repositorio. | Condiciones de los SDK y herramientas de Apple. [Acuerdos de Apple Developer](https://developer.apple.com/support/terms/). |
| SQLite | Biblioteca del sistema utilizada por el almacén. El paquete Swift no descarga una copia externa. | SQLite dedica su código distribuible al dominio público. [Declaración oficial](https://www.sqlite.org/copyright.html). |
| CUPS e `ippeveprinter` | El agente ejecuta `/usr/bin/ippeveprinter`; la instalación usa herramientas CUPS del sistema. No se redistribuyen aquí sus binarios ni fuentes. | OpenPrinting CUPS publica Apache-2.0 con excepciones. Para redistribuir una versión concreta deben comprobarse sus propios `LICENSE` y `NOTICE`. [Licencia de CUPS](https://openprinting.github.io/cups/doc/license.html). |
| Ghostscript | Conversión PostScript mediante un ejecutable externo. El empaquetado local copia un runtime suministrado por quien construye la app. | Ghostscript ofrece licencia AGPL y licencia comercial. El runtime de desarrollo comprobado corresponde a Ghostscript 10.08.0; no está incluido en esta publicación. [Licencias de Artifex](https://artifex.com/licensing). |

`native/Package.swift` no declara paquetes Swift externos. Los recursos `Info.plist` y `BandejaPDF.ppd` son configuración propia del proyecto. No se incluyen recursos, código ni binarios de PrintStack.

## Herramientas Python de desarrollo

Estas dependencias se instalan en un entorno virtual mediante [requirements-dev.txt](requirements-dev.txt). No se incorporan al bundle nativo de la app.

| Proyecto | Uso | Licencia y fuente oficial |
| --- | --- | --- |
| pypdf | Inspección y extracción de texto de PDFs de prueba. | BSD-3-Clause. [Licencia](https://github.com/py-pdf/pypdf/blob/main/LICENSE). |
| ReportLab | Generación de documentos sintéticos. | BSD. [Documentación del proyecto](https://docs.reportlab.com/developerfaqs/). |
| pypdfium2 | Enlace Python a PDFium para inspección y renderizado independiente. | Apache-2.0 / BSD-3-Clause para pypdfium2. PDFium y sus dependencias tienen avisos adicionales. [Licencias del proyecto](https://github.com/pypdfium2-team/pypdfium2#licensing). |
| Pillow | Escritura y manejo de imágenes de inspección. | MIT-CMU. [Licencia de la versión 12.3.0](https://github.com/python-pillow/Pillow/blob/12.3.0/LICENSE). |

Las versiones directas utilizadas se fijan en `requirements-dev.txt`. Los paquetes descargados pueden incluir bibliotecas auxiliares y sus propios avisos. En particular, los wheels de pypdfium2 suelen incluir PDFium: redistribuir ese entorno o sus binarios exige conservar las licencias correspondientes a esa compilación. La [documentación de pypdfium2](https://github.com/pypdfium2-team/pypdfium2#licensing) explica esta distinción. Este repositorio no redistribuye el entorno virtual.

## Antes de distribuir un runtime o un bundle

El soporte de empaquetado local no constituye una validación de redistribución. Sigue pendiente preparar un inventario de las versiones y archivos efectivamente incluidos en un futuro bundle, conservar los avisos aplicables y proporcionar el código fuente correspondiente cuando las licencias lo exijan.

Un runtime de Ghostscript puede contener bibliotecas auxiliares, programas de fuentes y CMaps con condiciones distintas. No debe tratarse todo el directorio como si tuviera una sola licencia ni suponerse que copiar un archivo `LICENSE` satisface todas las obligaciones. Deben revisarse los avisos de cada componente y los materiales que exija la versión exacta distribuida.

La elección `AGPL-3.0-only` para el código propio es una decisión de este proyecto; no certifica por sí sola el cumplimiento de un futuro paquete que incorpore Ghostscript u otros componentes. La publicación actual de fuentes no incluye una release binaria, firma Developer ID ni notarización.
