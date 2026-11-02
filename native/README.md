# Implementación nativa

Paquete Swift con tres ejecutables: `BandejaPDF`, `BandejaAgent` y `BandejaCLI`. Usa AppKit, PDFKit, Core Graphics, XPC y SQLite del sistema. El paquete declara macOS 15 como mínimo; el empaquetado local se construye para arm64.

- [Compilar, probar y preparar una instalación local](../docs/DEVELOPMENT.md).
- [Arquitectura y almacenamiento](../docs/ARCHITECTURE.md).
- [Pruebas y límites conocidos](../docs/TESTING.md).
- [Licencias de terceros](../THIRD_PARTY_NOTICES.md).

Los directorios `.build/`, `build/` y los resultados de pruebas son locales y están excluidos de Git. Los scripts de instalación e integración son pasos explícitos: compilar el paquete no los ejecuta.
