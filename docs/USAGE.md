# Uso de Bandeja PDF

Esta guía corresponde a la versión local de desarrollo. Presupone que la aplicación, su agente y la cola **Bandeja PDF** ya están instalados. La recepción requiere que el agente de la sesión esté activo; la interfaz puede estar cerrada.

## Recibir documentos

Desde otra aplicación, abre su diálogo de impresión y elige **Bandeja PDF**. Al terminar, abre la app y comprueba que el documento aparece y se puede previsualizar. La cola recibe PDF o PostScript; la app convierte el PostScript a PDF cuando el conversor está disponible.

Para incorporar PDFs existentes, usa **Abrir PDF…** (`⌘O`) o arrástralos al área de documentos o al visor. Puedes seleccionar varios. La app copia los archivos; no modifica los originales externos. La importación se detiene si un archivo falla: los que ya entraron permanecen y los restantes deberán añadirse después de resolver el problema.

La bandeja principal admite **10 documentos** y la espera otros **10**. El límite cuenta documentos, no páginas. Las nuevas impresiones pasan a la espera cuando la principal está llena. Al liberar un lugar, el primer documento en espera pasa automáticamente a la principal. **Abrir PDF…** requiere espacio en la principal y no utiliza la espera.

## Revisar el PDF y su texto

Selecciona un documento para ver sus páginas y miniaturas. Puedes previsualizar y guardar documentos tanto de la principal como de la espera; las operaciones de páginas se realizan en la principal.

El indicador de texto significa:

| Indicador | Qué comprueba |
| --- | --- |
| Texto seleccionable | Se detectó algún texto extraíble en cada página. |
| Texto parcial | Solo algunas páginas tienen texto extraíble. |
| Sin texto seleccionable | No se detectó texto extraíble. |

El indicador no certifica que todo el contenido se pueda copiar correctamente. La búsqueda (`⌘F`) usa el texto del PDF e ignora diferencias de mayúsculas y acentos. Las flechas junto al buscador recorren las coincidencias.

La app no incluye OCR. Si la aplicación de origen imprime las letras como imágenes o contornos, unir, girar o exportar ese documento no reconstruye sus caracteres. Las miniaturas se usan solo para visualizar; la exportación no convierte las páginas en capturas de pantalla.

## Organizar documentos y páginas

Selecciona varias filas o miniaturas con `⌘` o `Mayús`. Si no hay una selección explícita de páginas, se usa la página actual.

| Acción | Comportamiento actual |
| --- | --- |
| **Unir** | Une los documentos seleccionados de la principal en el orden de la bandeja. Conserva como destino el primero y retira los demás de la lista. |
| **Girar** | Gira 90° las páginas seleccionadas. |
| Flechas de orden | Mueven las páginas seleccionadas una posición antes o después. |
| **Extraer** | Mueve las páginas seleccionadas a un documento nuevo; las retira del anterior. Requiere espacio para el resultado. |
| **Agregar a…** | Añade las páginas al final de otro documento de la principal. Por defecto las mueve; marca **Conservar las páginas en el documento original** para copiarlas. |
| **Quitar páginas…** | Pide confirmación y quita las páginas seleccionadas. Si no queda ninguna, retira el documento. Se puede deshacer. |
| **Deshacer** (`⌘Z`) | Revierte la última edición disponible sin borrar impresiones nuevas. Puede pedir liberar espacio antes de restaurar documentos. |

Deshacer corresponde a la sesión del agente: no se conserva tras reiniciarlo. No hay Rehacer. El arrastre de páginas entre documentos con `Option` no está implementado; usa **Agregar a…**. El zoom y el tamaño de la ventana no cambian la composición del PDF.

Los PDFs con campos de formulario o marcadores se pueden abrir y guardar sin cambios, pero esta versión bloquea la composición de sus páginas. Los PDFs cifrados o protegidos se rechazan. La conservación de otras características complejas no está garantizada: revisa el resultado cuando edites ese tipo de documento.

## Guardar e imprimir

Selecciona un documento y usa **Guardar PDF…** (`⌘S`). Elige un destino fuera del almacenamiento interno de la aplicación. Guardar no elimina el documento de la bandeja ni libera espacio.

Cuando no cambiaste las páginas, la exportación copia exactamente el PDF almacenado. Si recibiste PostScript, se trata del PDF creado durante la conversión. Tras unir, extraer, girar o reordenar, la app genera un PDF desde las páginas originales mediante PDFKit.

**Imprimir…** (`⌘P`) abre el diálogo del sistema para enviar el documento a otra impresora. La app bloquea seleccionar su propia Bandeja PDF para evitar una nueva entrada circular. Esta función utiliza ajuste de página y rotación automática; la salida a impresoras físicas todavía necesita validación específica.

## Eliminar y liberar espacio

**Eliminar…** retira los documentos seleccionados de cualquiera de las bandejas, después de confirmar. **Vaciar…** permite eliminar los documentos mostrados de la principal o de ambas bandejas. Si vacías solo la principal, los documentos en espera pasarán a ella. Las impresiones que lleguen mientras está abierta la confirmación no se incluyen en ese vaciado.

**Eliminar documentos y vaciar son definitivos dentro de la app y borran todo el historial de Deshacer.** No borran los archivos originales externos ni los PDFs que guardaste en otra carpeta. No equivalen a **Quitar páginas…**, que sí permite deshacer mientras exista su historial.

## Cuando las dos bandejas están llenas

Al alcanzar **10 + 10**, aparece un aviso en una ventana de la propia aplicación. Mientras no se libere espacio, las siguientes impresiones se descartan y el aviso muestra cuántas se perdieron. Los documentos que ya estaban guardados permanecen.

Usa **Ver bandejas** para revisar y liberar espacio. **Aceptar** reconoce el aviso y reinicia su contador pendiente; no recupera las impresiones descartadas. Debes volver a imprimirlas desde la aplicación de origen después de liberar espacio. Un trabajo que figure completado en la cola del sistema puede haber sido descartado por esta condición: comprueba la bandeja.

El aviso no depende del Centro de notificaciones y su estado queda pendiente hasta reconocerlo. El agente puede abrir la app para mostrarlo. No se garantiza que aparezca encima de la pantalla bloqueada; el comportamiento completo con bloqueo, suspensión y modos de concentración sigue pendiente de pruebas.

## Errores y disponibilidad

Un formato no admitido, una conversión fallida o un error de almacenamiento se comunica como fallo, separado del descarte por capacidad. La app intenta conservar el original recibido cuando ocurre un error técnico, pero no puede garantizarlo si falla el disco. **Entendido** reconoce el aviso de error; no vuelve a procesar el trabajo.

Si aparece una operación sin confirmar o un tiempo de espera agotado, revisa la bandeja antes de repetirla: puede terminar más tarde. No se garantiza la eliminación de duplicados entre reinicios del receptor.

Cerrar la ventana o salir de la interfaz no detiene por sí solo el agente. Esto no garantiza recepción con el Mac apagado, la sesión cerrada o durante suspensión. La implementación está destinada al uso local; no ofrece una impresora compartida por red ni aislamiento definitivo entre cuentas del Mac.

Para detalles de almacenamiento, comunicaciones y límites, consulta [Arquitectura](ARCHITECTURE.md).
