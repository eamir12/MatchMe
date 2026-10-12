# MatchMe — Política de privacidad

**Fecha de entrada en vigor:** 1 de octubre de 2026
**Versión:** 1.0
**Estado:** Borrador — requiere revisión por un abogado cualificado antes del lanzamiento.

---

## 1. La versión breve

MatchMe conecta a personas que se encuentran en el mismo lugar, o que asistirán al mismo evento, en función de lo que buscan y de lo que les interesa. Te emparejamos en segundo plano. Tú no navegas ni deslizas.

Diseñamos el servicio partiendo de una idea sencilla: **no deberíamos conservar tu ubicación.**

- La ubicación en directo se elimina en minutos, no en meses.
- Las coordenadas exactas nunca se adjuntan a un emparejamiento.
- El registro detallado que nos permitiría construir un historial de tus movimientos está **desactivado por defecto**, es opcional y está limitado a 72 horas.

Sí hacemos comprobaciones automatizadas sobre tus fotos, y eso necesariamente implica enviarlas a un servicio externo de visión. Te explicamos exactamente en qué consiste en el apartado 6.

---

## 2. Quiénes somos

MatchMe es un servicio para conocer gente en persona. **No es una aplicación de citas** en el sentido en que podrías esperar: no hay navegación, no hay deslizar y no hay un listado de desconocidos que evaluar. Te emparejamos con personas según tus intenciones compartidas e intereses compartidos, combinados con la proximidad física en el mismo momento o con la asistencia al mismo evento futuro.

Las personas usan MatchMe con motivos distintos: para encontrar una pareja romántica, un amigo nuevo, alguien con quien hacer una actividad o un contacto profesional. Lo que buscas es asunto tuyo y es privado.

---

## 3. Qué recopilamos

### 3.1 Información que nos proporcionas

- **Datos de la cuenta:** nombre, fecha de nacimiento, género, idioma preferido, dirección de correo electrónico y el método de acceso que hayas elegido (correo y contraseña, código por correo, Google, Microsoft, Apple, Facebook o una passkey).
- **Contenido del perfil:** tu(s) foto(s), tu biografía, tus intereses, el tipo de conexiones que buscas y, opcionalmente, datos sobre estilo de vida, familia, religión, idiomas, altura, formación, ocupación y enlaces sociales.
- **Eventos:** los eventos que añades a tu calendario, para poder saber cuándo tú y otra persona estaréis en el mismo lugar al mismo tiempo.
- **Mensajes:** el contenido de los chats que envías y recibes.
- **Denuncias y medidas de seguridad:** si denuncias o bloqueas a otro usuario, lo almacenamos.

### 3.2 Información recopilada automáticamente

- **Ubicación**, mientras la aplicación está abierta y mientras el acceso a la ubicación en segundo plano está activado. Consulta el apartado 4: es la parte más importante de esta política.
- **Información del dispositivo y de la sesión:** un registro de sesión con un identificador, la plataforma del dispositivo y un token de notificaciones push. Usamos el token para entregar notificaciones a ese dispositivo. Se elimina cuando se revoca la sesión o cuando eliminas tu cuenta.
- **Ubicación aproximada derivada de tu dirección IP,** utilizada para estimar tu zona horaria y el área del mapa por defecto. La deriva tu proveedor de alojamiento a partir de la conexión; nosotros no la almacenamos como ubicación.
- **Eventos de interacción con publicidad**, si se te muestra publicidad: que se ha mostrado un anuncio, que se ha hecho clic y los ingresos que ha generado. Consulta el apartado 7.

### 3.3 Lo que **no** recopilamos

- No elaboramos un perfil de tus movimientos a lo largo del tiempo. No predecimos dónde estarás.
- No utilizamos el contenido de tus mensajes para entrenar ningún modelo de aprendizaje automático.
- No vendemos tu información personal. No la compartimos con nadie con ese fin.

---

## 4. Ubicación: los detalles

Este apartado es deliberadamente específico. «¿Cuánto tiempo conservan mi ubicación?» merece algo más que una frase, porque la respuesta honesta tiene excepciones.

### 4.1 Ubicación en directo: 15 minutos

Mientras MatchMe está abierta y mientras el acceso a la ubicación en segundo plano está activado, tu dispositivo nos envía tu posición. Almacenamos una única posición actual por usuario, junto con la velocidad y la dirección de movimiento. Una tarea programada elimina las posiciones con más de **15 minutos** de antigüedad.

El motor de emparejamiento solo considera a un usuario cuya posición se haya actualizado en los últimos minutos, de modo que una posición obsoleta no puede utilizarse para generar un emparejamiento.

### 4.2 Ubicaciones fijadas: hasta 30 días, solo si tú estableces una

Puedes fijar deliberadamente tu ubicación actual como «base» —por ejemplo, tu casa o tu lugar de trabajo— durante el periodo que elijas. Si lo haces:

- Una ubicación fijada puede establecerse entre **60 segundos y 30 días**, y el tiempo total que puede vivir una sola fijación está limitado a 30 días desde su creación.
- La eliminación a los 15 minutos descrita arriba **no se aplica a una fijación activa.** Esta es la excepción más importante de toda esta política.
- Mientras una fijación está activa, tu posición en directo no la sobrescribe.
- Una fijación caducada se elimina automáticamente.
- Puedes eliminar una fijación en cualquier momento.

Elegimos que esta sea una acción explícita, visible y limitada en el tiempo, en lugar de un comportamiento automático, porque una ubicación «de casa» permanente sería exactamente el tipo de registro permanente que esta política evita por lo demás.

### 4.3 El registro opcional: desactivado por defecto, hasta 72 horas

Si activas el registro opcional, almacenamos dónde has estado para poder presentarte a personas que estaban cerca de ti en otro momento, incluso mientras la aplicación estaba cerrada.

- **Está desactivado por defecto.** Debes activarlo tú mismo.
- Tú eliges cuánto tiempo se conserva: **entre 2 y 72 horas.** El valor predeterminado es 24 horas.
- Los puntos demasiado imprecisos para ser útiles se descartan.
- Si desactivas la función o acortas el periodo de retención, los puntos almacenados se **eliminan**, no simplemente se dejan de consultar.
- Puedes eliminar todo el registro tú mismo, tanto en tu dispositivo como en nuestros servidores, en cualquier momento.
- La tabla que contiene estos datos no admite acceso directo de ningún usuario o cliente; solo puede alcanzarse a través de nuestras propias funciones de emparejamiento.

### 4.4 Qué contiene un emparejamiento y qué no

Cuando dos personas son emparejadas, **no** almacenamos las coordenadas de ninguna de las dos en el emparejamiento. Eliminamos deliberadamente esas columnas de nuestra base de datos.

Un emparejamiento sí contiene un **centro de mapa aproximado**, redondeado a aproximadamente un kilómetro, y un nivel de zoom. Sirve para dibujar un mapa pequeño sin un pin. Por sí solo, una ubicación redondeada a un kilómetro no identifica a una persona, pero queremos que sepas que existe.

Por separado, cuando un emparejamiento caduca sin que ninguna de las dos personas haya enviado un mensaje, conservamos un pequeño historial de hasta tres centros de mapa aproximados para esa pareja, de modo que podamos reconocer un encuentro repetido. **Este historial no tiene actualmente caducidad automática.** Si deseas que se borre, escríbenos según los datos del apartado 12 y lo eliminaremos.

### 4.5 Ubicación en directo compartida entre emparejados

Si tú y tu pareja decidís compartir vuestra posición en directo, vuestra posición se envía directamente al dispositivo de la otra persona a través de un canal cifrado, en lugar de almacenarse. La sesión tiene una cuenta atrás visible y finaliza al caducar o cuando cualquiera de los dos la termina.

### 4.6 Permisos

MatchMe solicita permiso de ubicación porque no puede funcionar sin él. En Android e iOS esto incluye la **ubicación en segundo plano**, que permite a la aplicación buscar emparejamientos mientras está cerrada. También solicita acceso a la cámara (para capturar fotos y verificar la identidad) y al calendario (para el emparejamiento por eventos). Cada permiso se solicita en el momento en que lo necesitamos, no todos de golpe. Puedes rechazar cualquiera de ellos; si rechazas la ubicación, MatchMe no podrá emparejarte por proximidad.

---

## 5. Fotos, verificación de identidad y análisis facial

Este apartado describe el procesamiento automatizado de tus fotografías. Creemos que deberías saberlo antes de subir nada.

### 5.1 Revisión automatizada de fotos

Cada foto que subes se revisa automáticamente. La imagen en sí —el archivo de imagen real— se envía a un servicio externo de visión operado por Google (los modelos Gemini) para poder comprobarla.

Esa revisión busca: desnudez o contenido sexual; si la foto parece mostrar a un menor; si es una foto del cuerpo en lugar de un rostro; si contiene más de una persona; si es un meme o arte generado en lugar de una foto real; y si el texto de la imagen debe oscurecerse. Según el resultado, la foto puede aceptarse, rechazarse o aceptarse con el texto pixelado.

### 5.2 Verificación de identidad

Puedes verificar opcionalmente tu identidad haciendo un selfie en directo. La verificación compara ese selfie con la foto de tu perfil, por lo que ambas imágenes se envían al mismo servicio externo para esa comparación.

- **El selfie de verificación se elimina 14 días después de enviarse.**
- La verificación significa que MatchMe revisó un selfie frente a la foto de perfil. **No garantiza la seguridad de nadie ni su comportamiento futuro.** Por favor, no trates la insignia de verificado como una garantía.

### 5.3 Un descriptor facial derivado

Como parte de la verificación, el sistema extrae una descripción numérica de la geometría facial: proporciones como la relación entre la longitud y la anchura del rostro, la distancia entre los ojos y mediciones similares. Es una lista de números, no una imagen, y existe para reducir el fraude.

**Debemos ser claros en que esto es información sensible.** Se deriva de tu rostro. Se almacena en tu cuenta tras la verificación. Actualmente **no** se elimina junto con la eliminación de 14 días descrita arriba, y solo se limpia si un administrador restablece tu verificación. Si prefieres que no se conserve, pídanos que lo eliminemos (apartado 12) o no completes la verificación: la verificación es opcional y todo lo demás funciona sin ella.

---

## 6. Mensajes y traducción

Los mensajes entre tú y tu pareja se cifran en tu dispositivo antes de enviarse y se almacenan cifrados.

Puedes activar la traducción para un chat concreto. Si lo haces, **el texto de tus mensajes se envía a DeepL**, un proveedor externo de traducción, para que sea traducido. Si dejas la traducción desactivada, el texto de los mensajes no se envía a DeepL.

No utilizamos el contenido de tus mensajes para entrenar ningún modelo de aprendizaje automático.

La traducción automática es una traducción automática y puede ser incorrecta o inapropiada. Trátala como una ayuda aproximada, no como una reconstrucción fiel de lo que escribió la otra persona.

---

## 7. Publicidad

Según el nivel de tu suscripción, MatchMe puede mostrar publicidad. La publicidad se sirve a través de **Google AdMob** y también operamos nuestras propias ubicaciones patrocinadas internas.

- Tu elección de consentimiento se registra y se envía a Google con la solicitud de anuncio.
- La publicidad está configurada como no personalizada por defecto.
- Puedes cambiar tu elección de consentimiento en cualquier momento.
- No permitimos publicidad conductual dirigida a usuarios que sabemos que están por debajo de la edad mínima aplicable.

Si se te muestra publicidad puede depender de tu nivel de suscripción. Esto se configura por nuestra parte y puede cambiar; no retiraremos la publicidad de un plan de pago sin avisar.

No utilizamos tu ubicación precisa para dirigir publicidad.

---

## 8. Con quién compartimos tu información

Compartimos lo mínimo necesario con las siguientes categorías de proveedores. Cada uno está sujeto a una obligación contractual de confidencialidad.

| Proveedor | Función | Qué recibe |
|---|---|---|
| **Supabase** | Alojamiento: base de datos, autenticación, almacenamiento de archivos, mensajería en tiempo real y las funciones de backend que ejecutan nuestro emparejamiento | Todo lo que tenemos, porque es nuestra infraestructura. La ubicación compartida en directo pasa por su capa de tiempo real en tránsito |
| **Google Firebase Cloud Messaging** | Entrega notificaciones push | Las notificaciones push y el token de empuje de tu dispositivo |
| **Google AdMob** | Sirve publicidad | Solicitudes de anuncios y tu elección de consentimiento, además de los datos que la red publicitaria recibe según su propia política |
| **Google Gemini** | Revisión automatizada de fotos y biografía, y verificación de identidad | Tus fotos y selfies de verificación, como datos de imagen; el texto de tu biografía |
| **DeepL** | Traducción de mensajes y notificaciones, solo donde tú o la aplicación hay habilitado la traducción | El texto del mensaje o de la notificación |
| **Resend** | Envía correo electrónico transaccional, incluidos códigos de verificación | Tu dirección de correo electrónico; para algunos mensajes, un nombre visible y un identificador de emparejamiento |
| **Cloudflare Turnstile** | Protección contra bots | El token del CAPTCHA generado por el widget |
| **OpenStreetMap** | Teselas de mapa y búsqueda de direcciones | Solicitudes de teselas de mapa (que revelan el área que estás viendo) y consultas de búsqueda de direcciones |
| **Google, Microsoft, Apple, Facebook** | Acceso mediante OAuth, si lo utilizas | Los datos de identidad que esos proveedores nos devuelven |
| **Proveedores de calendario** (Google Calendar, Outlook, calendario del dispositivo) | Lee los eventos que hayas vinculado, para el emparejamiento por eventos | Acceso al calendario; las credenciales se eliminan al eliminar tu cuenta |

No vendemos tu información personal ni la revelamos a terceros para sus propios fines de marketing.

**Transferencias internacionales.** Algunos de estos proveedores procesan datos fuera de tu país. Cuando así ocurre, las transferencias se apoyan en una garantía adecuada, como cláusulas contractuales tipo.

---

## 9. Durante cuánto tiempo conservamos los datos

| Dato | Conservación |
|---|---|
| Ubicación en directo | 15 minutos |
| Una ubicación fijada | El periodo que elijas, hasta 30 días desde su creación |
| El registro opcional | De 2 a 72 horas, como elijas; se elimina de inmediato si lo desactivas |
| Selfie de verificación | 14 días |
| Descriptor de geometría facial | Hasta que nos pidas que lo eliminemos, o un administrador restablezca tu verificación |
| Mensajes de chat | Hasta que los borres, desvincules la coincidencia o elimines tu cuenta |
| Centro de mapa aproximado en un emparejamiento | Mientras exista el emparejamiento |
| Historial de encuentros aproximados de emparejamientos caducados | **Sin caducidad automática por ahora**: pídenos y lo eliminaremos |
| Cuenta | Hasta que la elimines; después se retira de nuestros sistemas activos |

**Eliminación de tu cuenta.** Puedes eliminar tu cuenta tú mismo desde Ajustes. La eliminación requiere que estés en línea y que vuelvas a confirmar tu identidad. Elimina tu perfil y tus fotos de nuestro almacenamiento, cierra tus sesiones, borra los datos almacenados localmente y solicita la eliminación de tus registros en nuestra plataforma.

---

## 10. Tus derechos

Según dónde vivas, puedes tener derecho a:

- acceder a los datos personales que tenemos sobre ti;
- corregir datos que sean inexactos;
- eliminar tu cuenta y tus datos;
- restringir u oponerte a determinados tratamientos;
- recibir una copia de tus datos en formato portable;
- retirar tu consentimiento, cuando ese sea el fundamento en que nos basamos;
- presentar una reclamación ante tu autoridad local de protección de datos.

**Para ejercer cualquiera de ellos, utiliza los controles dentro de la aplicación cuando existan (eliminar tu cuenta, eliminar tu registro, cambiar tu elección de consentimiento, bloquear o denunciar a un usuario) o escríbenos con los datos del apartado 12.**

Responderemos en un plazo razonable y nuestro objetivo es completar las solicitudes en un plazo de 30 días.

Dos cosas que queremos decirte con claridad:

- **No ofrecemos actualmente una exportación automática de tus datos.** Si quieres una copia, escríbenos y te la proporcionaremos.
- **Si recibimos una denuncia sobre un usuario, la registramos, pero no podemos prometer que una persona la revise.** Preferimos ser honestos al respecto antes que dar a entender un equipo de moderación que no hemos descrito.

---

## 11. Seguridad

Utilizamos cifrado en tránsito. Los datos almacenados en tu dispositivo están cifrados. Los mensajes se cifran antes de enviarse. Las acciones sensibles, como cambiar tu correo electrónico o tu contraseña, requieren un código enviado a tu correo o una confirmación mediante passkey.

Ningún sistema es perfectamente seguro. Si una brecha afecta a tus datos, te lo notificaremos y notificaremos a la autoridad competente según exige la ley.

Si eres investigador de seguridad, communicate las vulnerabilidades en lugar de explotarlas o acceder a los datos de otras personas.

---

## 12. Contacto

Para cualquier pregunta sobre privacidad, solicitud de datos, o para pedirnos que eliminemos algo que tenemos sobre ti, escríbenos a:

**privacy@matchme.app**

Al escribirnos sobre un dato concreto, indica la dirección de correo electrónico o el identificador de la cuenta. Podemos pedirte que confirmes tu identidad antes de atender la solicitud.

---

## 13. Menores de edad

**MatchMe no está dirigida a menores de 18 años y no permitimos deliberadamente que menores de 18 creen una cuenta.** El requisito de edad se comprueba al completar tu perfil.

Sabemos que esto no es lo mismo que aplicarlo técnicamente, y no vamos a fingir lo contrario. Si crees que un menor ha creado una cuenta, escríbenos y la eliminaremos.

---

## 14. Cambios en esta política

Podemos actualizar esta política. Cuando hagamos un cambio importante te avisaremos en la aplicación antes de que entre en vigor. Mantendremos el número de versión y la fecha de entrada en vigor al principio de este documento.

---

<!-- matchme:internal-notes-end -->

## Apéndice — Notas de redacción (eliminar antes de la publicación)

1. **Requiere revisión jurídica antes del lanzamiento.** No publicar tal cual.
2. **Apartado 9: los emparejamientos caducados no tienen caducidad.** `unmatched_pairs.locations_history` no tiene TTL ni control de borrado por parte del usuario. La corrección recomendada es sustituir las coordenadas por una etiqueta de clase aproximada, añadir un TTL de 30 días y añadir un control «olvidar este emparejamiento». Hasta entonces, este apartado debe conservar la advertencia y la promesa de atención manual de la sección 10 se convierte en un compromiso operativo.
3. **Apartado 5.3: el descriptor facial sobrevive al selfie.** La limpieza de 14 días anula `verification_photo_path` pero no `verification_reference_artifact`.
4. **Los artículos 5.2 y 5.3 deben mantenerse claramente separados:** no conservamos la imagen, pero sí el descriptor.
5. **Apartado 7: «puede depender de tu nivel de suscripción» es estado de configuración, no código.** Las migraciones se contradicen entre sí. Lee la tabla `app_config` en vivo antes de convertirlo en una promesa.
6. **Apartado 13: la comprobación de los 18 años es solo del lado del cliente.** No hay restricción en la base de datos.
7. **Localización:** este texto está disponible en inglés, español y hebreo. Varias jurisdicciones exigen una versión localizada para los usuarios de esa jurisdicción, revisada por un profesional del idioma.
