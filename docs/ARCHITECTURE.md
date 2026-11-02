# Arquitectura

Esta documentación describe la implementación local actual. El paquete Swift declara macOS 15 como versión mínima; la construcción de desarrollo está orientada a Apple Silicon. No implica compatibilidad comprobada con todos los equipos o versiones posteriores.

## Componentes y recorrido de una impresión

```text
Aplicación que imprime
  → cola CUPS «Bandeja PDF» (bandeja_pdf)
  → receptor IPP local, puerto 18633
  → BandejaCLI
  → XPC
  → BandejaAgent / BandejaCore
  → archivos originales, PDF y estado SQLite

BandejaUI → XPC → BandejaAgent
          ← estado y ruta de vista previa
```

| Componente | Responsabilidad |
| --- | --- |
| `BandejaShared` | Modelos de solicitudes, respuestas, documentos y páginas; cliente y protocolo XPC. |
| `BandejaCore` | Recepción, composición, capacidad, Deshacer y persistencia. |
| `BandejaAgent` | Único escritor del almacenamiento; serializa solicitudes y supervisa el receptor. |
| `BandejaCLI` | Adapta cada trabajo del receptor a una solicitud XPC; también permite consultar el estado o enviar solicitudes JSON locales. |
| `BandejaUI` | Interfaz AppKit, visor PDFKit, miniaturas y avisos propios. No escribe directamente el estado de la bandeja. |

El agente se registra mediante un LaunchAgent de desarrollo en la sesión gráfica. Es independiente de la interfaz: cerrar la ventana o salir de ella no detiene por sí solo la recepción. El receptor es el `ippeveprinter` del sistema, ejecutado con el PPD del proyecto, sin Bonjour ni formularios web. El agente verifica que sus direcciones de escucha sean únicamente loopback. Si el receptor termina, el agente sale para que launchd reinicie el servicio.

La interfaz consulta el estado por XPC y solicita al agente las operaciones. Las solicitudes se ejecutan en una cola serial; un bloqueo de archivo impide iniciar dos agentes sobre el mismo almacén. La conexión XPC exige el mismo identificador de usuario que el agente. Esto no verifica la identidad de la aplicación cliente ni autentica el puerto IPP frente a otras cuentas locales.

## Archivos, estado y confirmación

Los datos se guardan en `~/Library/Application Support/BandejaPDF`. El índice reside en SQLite, con WAL y sincronización `FULL`; actualmente almacena el estado codificado como JSON en una fila transaccional.

Cada entrada tiene una copia del archivo original y un `content.pdf`. Una entrada PDF se copia; una entrada PostScript se convierte con Ghostscript. El original externo nunca se modifica. El conversor se obtiene del paquete local, ejecuta `pdfwrite` con `SAFER`, limita el tiempo de conversión y no acepta opciones de Ghostscript heredadas del entorno.

La recepción prepara los archivos en un directorio temporal, comprueba el hash de la copia, valida el PDF y confirma los archivos antes de incorporar sus referencias al índice. Un cambio se publica en memoria después de guardar el estado en SQLite. La limpieza de archivos que ya no están referenciados ocurre después de esa confirmación. Este orden reduce inconsistencias, pero no constituye una garantía de recuperación ante cualquier fallo de disco o caída abrupta.

El adaptador devuelve el resultado al receptor después de recibir la respuesta del agente. Los resultados distinguen documento guardado, documento en espera, descarte por capacidad y fallo técnico. **Un descarte por capacidad es una respuesta procesada correctamente**, por lo que un trabajo completado en CUPS no demuestra que exista un documento en la bandeja.

Para evitar duplicados, cada recepción combina un identificador nuevo por arranque del receptor con su identificador de trabajo IPP. El recibo conserva el hash y el resultado: repetir la misma clave y contenido devuelve el resultado anterior; repetir la clave con otro contenido se rechaza. La clave cambia al reiniciar el receptor: no se garantiza entrega exactamente una vez entre reinicios o retransmisiones.

## Capacidad y avisos

La bandeja principal admite 10 documentos y la espera otros 10, independientemente de su número de páginas. Las impresiones ocupan primero la principal y después la espera. Cuando se libera espacio, se promueve automáticamente el primer documento en espera. La importación manual solo entra en la principal y se rechaza cuando esta tiene 10 documentos.

Al alcanzar 10 + 10 se guarda un aviso pendiente. Mientras ambas bandejas sigan llenas, cada nueva impresión admitida para recepción se descarta, incrementa el contador y actualiza la versión del aviso. No se conserva como documento recuperable. Los documentos que ya estaban en las bandejas no se sustituyen.

El agente solicita abrir la interfaz cuando aparece un aviso nuevo. La ventana pertenece a la app y no usa el Centro de notificaciones. El aviso permanece pendiente hasta reconocer su versión; un reconocimiento antiguo no oculta un descarte posterior. Aceptarlo reinicia el contador pendiente, pero no recupera trabajos. No se promete mostrar la ventana encima de una sesión bloqueada ni se ha validado todo el comportamiento con modos de concentración, suspensión o cierre de sesión.

Los errores técnicos no se cuentan como descartes por capacidad. Se devuelven como fallos y, en recepción de impresiones, se registra un error visible. El núcleo intenta conservar el original en el área de fallos o en su directorio de preparación. Si el disco no permite escribir, esa conservación y la persistencia del aviso pueden fallar; no se informa éxito para ocultarlo.

## Composición y texto

Un documento es una secuencia de referencias a páginas de los originales, con una rotación adicional por página. Unir, girar, ordenar, extraer o copiar modifica esas referencias. PDFKit genera el PDF compuesto cuando se necesita previsualizarlo o exportarlo. Las miniaturas son imágenes de pantalla y nunca se usan como páginas de exportación.

Si el documento sigue conteniendo todas las páginas de un único PDF, en el orden original y sin giros adicionales, se utiliza `content.pdf` directamente. La exportación copia ese PDF byte a byte mediante un archivo temporal en el destino. Para entradas PostScript, esta identidad corresponde al PDF convertido, no al PostScript original. Una composición editada se vuelve a escribir con PDFKit; no se promete fidelidad completa para todos los tipos de PDF.

La detección de texto comprueba si PDFKit extrae algún texto no vacío por página. Los estados indican texto en todas las páginas, en algunas o en ninguna. No verifican la exactitud, integridad ni orden de lectura de los caracteres. No hay OCR: un escaneo o letras convertidas en contornos no adquieren texto seleccionable por unir o exportar el documento.

Se rechazan archivos cifrados, protegidos, vacíos, inválidos o de formatos distintos de los admitidos. Los PDFs con campos de formulario o marcadores pueden conservarse y exportarse sin cambios; las operaciones de composición sobre sus páginas se bloquean. Otras estructuras complejas no tienen una garantía general de conservación.

## Deshacer y eliminación

Deshacer guarda en memoria los documentos afectados por cada edición. Restaura esos documentos conservando las nuevas llegadas ajenas a la operación, y rechaza el cambio completo si no cabe dentro de 10 + 10. Los originales necesarios siguen referenciados mientras exista una operación que pueda restaurarlos. El historial se pierde al reiniciar el agente.

Quitar páginas es una edición reversible; si el documento queda vacío, se retira. Eliminar documentos o vaciar bandejas borra el historial de Deshacer. La interfaz de vaciado captura los identificadores antes de abrir la confirmación y envía únicamente esos identificadores para conservar las llegadas posteriores. La operación interna `clear` del protocolo actúa sobre el estado presente al ejecutarse; la interfaz no la utiliza para ese diálogo.

## Límites de esta versión

- El receptor del sistema con PPD anuncia formatos de imagen que el núcleo rechaza. La ruta admitida es la cola instalada para PDF/PostScript; no se ofrece compatibilidad general con clientes IPP directos.
- El puerto IPP no autentica otras cuentas locales. Loopback evita exposición por interfaces de red, pero no resuelve el aislamiento entre usuarios del mismo Mac.
- La firma de desarrollo, LaunchAgent y construcción local no son un instalador público terminado. SMAppService, firma de distribución, notarización y empaquetado de dependencias no están implementados como entrega final.
- El código no traduce de forma propia todas las opciones IPP, como copias o rangos. No se garantiza soporte general de opciones de impresión de cualquier cliente.
- Reinicio completo, suspensión, disco lleno, recuperación abrupta y consumo con documentos grandes requieren más validación. El límite de documentos no impone un límite de páginas ni de bytes.

Para el funcionamiento de la interfaz, consulta [Uso](USAGE.md). Los componentes están en [`native/Sources`](../native/Sources) y sus dependencias, en [`Package.swift`](../native/Package.swift).
