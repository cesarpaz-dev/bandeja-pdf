# Validación

Última actualización: **2 de noviembre de 2026**. Se distinguen las pruebas del almacenamiento, la instalación local y la impresión desde aplicaciones. Una prueba aprobada con una muestra no garantiza todas las variantes de un formato.

## Núcleo aislado

Once casos comprueban capacidad 10 + 10, descarte, deduplicación, reinicio del almacenamiento, avisos por versión, promoción FIFO, importación y extracción a capacidad completa, originales, exportación exacta, protección del almacenamiento, operaciones de páginas, Deshacer con nuevas llegadas y errores de conversión.

El 2 de noviembre pasaron **11/11** en el ejecutor independiente, tanto con productos Swift Build como con el layout nativo de SwiftPM. Se usó Apple Swift 6.4.2, Apple Silicon y Ghostscript 10.08.0. Los documentos se generaron en directorios temporales; no se contactó con la impresora instalada. El caso PostScript falla expresamente si falta su conversor.

Los comandos están en [desarrollo](DEVELOPMENT.md). La declaración de herramientas Swift 5.9 y macOS 15 en el paquete no equivale a probar todas esas versiones.

## Integración local

Se comprobó la ruta CUPS → IPP → CLI → XPC → almacenamiento → exportación con un PDF y un PostScript sintéticos. Se verificaron texto, tamaños y conservación del PDF recibido al exportar sin cambios.

También se comprobaron unión, giro, búsqueda, selección múltiple de miniaturas, Deshacer y bloqueo de impresión hacia la propia cola desde la interfaz. Un reinicio controlado del agente con la interfaz cerrada conservó los documentos. Esto no representa un reinicio completo del Mac ni una caída abrupta.

## Aplicaciones de origen

Pruebas realizadas el 1 de noviembre de 2026 contra una instalación local:

| Aplicación | Entrada recibida | Páginas | Texto seleccionable | Resultado |
| --- | --- | --- | --- | --- |
| SIDUNEA | PostScript | 2 A3 vertical | No | Recepción, conversión y exportación comprobadas. Las letras ya llegaban como contornos. |
| Vista Previa | PDF | 2 A4 vertical | Sí | Texto normalizado completo, orden y marcadores conservados; revisión visual sin recortes. |
| TextEdit | PDF | 1 A4 vertical | Sí | Cifras, ceros iniciales, acentos y contenido de control conservados. |
| Safari | PDF | 1 A4 vertical | Sí | Texto del HTML completo y tabla conservados; búsqueda funcional en la app. |

Las tres muestras controladas contenían texto y elementos vectoriales; los PDF recibidos no contenían imágenes. Las cuatro exportaciones sin edición fueron idénticas byte a byte a sus PDF almacenados. En PostScript, esa comparación empieza después de la conversión.

Vista Previa redondeó el papel A4 a 595 × 842 puntos y aplicó un ajuste de escala mínimo durante la reimpresión. Se distingue el archivo previo a imprimir del PDF recibido por la app.

Los reportes reales y capturas quedan fuera del repositorio. Los scripts públicos generan sus propios datos de prueba; estos resultados no constituyen una auditoría del contenido de SIDUNEA.

## Pendiente

- Prueba de la ventana de saturación con No molestar, sesión bloqueada y desbloqueo.
- Reinicio completo, suspensión, disco lleno, caída abrupta y reintentos del receptor.
- Otros usuarios locales, otras versiones de macOS y Mac limpio.
- PDF complejos, firmas digitales, estructuras avanzadas y documentos grandes.
- Salida a una impresora física desde la app.

## Validación en GitHub

Antes de preparar el repositorio se revisaron 41 archivos publicables y se construyó una copia limpia que contiene solo esos archivos. Esa copia compiló los tres ejecutables en Release para arm64 y aprobó de nuevo los 11 casos del núcleo con el conversor indicado explícitamente. También pasaron sintaxis Python/shell, recursos plist/PPD, revisión de enlaces y estructura YAML del workflow. Ningún paso instaló la impresora ni modificó su configuración.

El workflow comprueba el árbol público, compila y ejecuta las pruebas del núcleo en macOS. No instala la cola, no abre la app, no ejecuta el smoke y no publica paquetes. Su primera ejecución en GitHub queda pendiente hasta subir el repositorio.
