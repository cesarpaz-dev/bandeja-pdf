# Próximos pasos

La primera versión local ya recibe impresiones y permite organizar y exportar PDF. Esta lista describe trabajo pendiente; no es un anuncio de funciones disponibles ni de fechas de entrega.

## Fiabilidad y aislamiento

- Identificar reintentos de forma estable entre reinicios del receptor y verificar recuperación ante caídas.
- Probar disco lleno, suspensión, reinicio completo y sesión bloqueada.
- Probar la ventana propia con las dos bandejas llenas y No molestar, manteniendo visible el aviso de descartes pendientes.
- Resolver el acceso de otras cuentas locales al puerto IPP.
- Alinear los formatos que anuncia el receptor con los PDF/PostScript que acepta el núcleo.

## Documentos e interfaz

- Ampliar muestras de PDF y verificar fidelidad de composición, fuentes y anotaciones.
- Mantener bloqueadas las operaciones sobre formularios y marcadores hasta validar su conservación.
- Añadir arrastre de páginas y copia con modificador, complementando «Agregar a…».
- Medir consumo con documentos grandes y completar accesibilidad y atajos.
- Investigar una salida con texto desde aplicaciones antiguas. OCR sería una función separada y explícita; no se presupone precisión ni se cambia automáticamente el contenido recibido.

## Distribución

- Preparar de forma reproducible el runtime de conversión y sus dependencias.
- Completar inventario de licencias, avisos y fuentes correspondientes del paquete distribuible.
- Integrar el mecanismo definitivo de inicio de sesión, instalación, actualización y desinstalación.
- Incorporar firma Developer ID, notarización y pruebas en un Mac limpio.
- Validar las versiones de macOS que se anunciarán como compatibles.

La publicación inicial del código bajo AGPLv3 no incluye una release binaria. El proyecto se centra en Apple Silicon; no se promete soporte Intel.
