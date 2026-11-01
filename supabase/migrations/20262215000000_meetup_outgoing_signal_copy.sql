-- Meet-up hub: the sender's own signal becomes visible.
--
-- Sending a gesture left only a transient banner, so the hub looked identical
-- before and after and there was no way to tell whether the other person had
-- been signaled — while Spot me shows its own card and Live location shows its
-- countdown. The client already holds your last sent signal with its gesture
-- and its server-set expiry, so this is display-only copy: a card in the
-- coordination feed ("You sent Dana a signal / Both hands up / still visible
-- for another 42 seconds"), a status pill on the Signal tile, and the tile's
-- action flipping to "Send again".
--
-- The countdown inside meetupSignalOutgoingVisible is the existing
-- locationShareCountdownRemaining row, which since
-- 20262214000000_location_share_countdown_es_gender.sql names no noun and
-- therefore agrees with whatever unit the timer lands on.
--
-- Hebrew keeps the Beacon ruling from 20262211000000: the beacon is איתות,
-- while this tool stays תנועה — feminine, so both participles inflect
-- feminine (נראית, נשלחה). Spanish agrees with the feminine señal (Enviada).

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupSignalOutgoingKicker', 'You sent {name} a signal'),
('es', 'meetupSignalOutgoingKicker', 'Enviaste una señal a {name}'),
('he', 'meetupSignalOutgoingKicker', 'שלחת תנועה ל-{name}'),
('en', 'meetupSignalOutgoingVisible', 'Still visible {time}'),
('es', 'meetupSignalOutgoingVisible', 'Sigue visible {time}'),
('he', 'meetupSignalOutgoingVisible', 'עדיין נראית {time}'),
('en', 'meetupSignalOutgoingPill', 'Sent'),
('es', 'meetupSignalOutgoingPill', 'Enviada'),
('he', 'meetupSignalOutgoingPill', 'נשלחה'),
('en', 'meetupHubSignalAgain', 'Send again'),
('es', 'meetupHubSignalAgain', 'Enviar de nuevo'),
('he', 'meetupHubSignalAgain', 'לשלוח שוב')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
