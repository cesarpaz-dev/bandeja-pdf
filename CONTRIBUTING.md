# Contribuir

Lee [desarrollo](docs/DEVELOPMENT.md) y [arquitectura](docs/ARCHITECTURE.md) antes de cambiar la recepción, el almacenamiento o la edición de páginas.

## Cambios

1. Trabaja en una rama y limita cada cambio a un problema concreto.
2. Usa documentos sintéticos. No incorpores reportes reales, bases de datos, registros de impresión, credenciales ni capturas de otras aplicaciones.
3. Ejecuta las pruebas relacionadas. Si cambias recepción, capacidad, persistencia o exportación, incluye una comprobación del comportamiento afectado.
4. Ejecuta `python3 scripts/check-public-tree.py` desde la raíz.
5. Explica el problema, el comportamiento final y cómo lo verificaste en el pull request.

Los comandos de integración que envían impresiones son optativos y deben apuntar exclusivamente a la cola de desarrollo. Las pruebas unitarias no necesitan instalar ni iniciar la app.

## Informar un problema

Indica la versión de macOS, arquitectura del Mac, versión de la app, aplicación que imprime, papel y pasos mínimos. Explica qué esperabas y qué ocurrió. Si necesitas un archivo para reproducirlo, crea uno con datos inventados y revisa sus metadatos.

No pegues registros completos sin revisarlos: pueden contener nombres de documentos, rutas e identificadores. Para posibles fallos de seguridad, no publiques datos de acceso ni documentos ajenos; usa el canal privado de reporte de GitHub si el repositorio lo tiene habilitado.

Las contribuciones al código propio se integran bajo [AGPL-3.0-only](LICENSE). No añadas código, fuentes o binarios de terceros sin identificar su procedencia y condiciones.
