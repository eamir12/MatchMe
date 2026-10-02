INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileWizardEditPhotoAction', 'Edit photo'),
  ('en', 'profileWizardRemovePhotoAction', 'Remove photo'),
  ('en', 'profileWizardMovePhotoEarlier', 'Move photo earlier'),
  ('en', 'profileWizardMovePhotoLater', 'Move photo later'),
  ('es', 'profileWizardEditPhotoAction', 'Editar foto'),
  ('es', 'profileWizardRemovePhotoAction', 'Eliminar foto'),
  ('es', 'profileWizardMovePhotoEarlier', 'Mover foto antes'),
  ('es', 'profileWizardMovePhotoLater', 'Mover foto después'),
  ('he', 'profileWizardEditPhotoAction', 'עריכת תמונה'),
  ('he', 'profileWizardRemovePhotoAction', 'הסרת תמונה'),
  ('he', 'profileWizardMovePhotoEarlier', 'העברת התמונה קודם'),
  ('he', 'profileWizardMovePhotoLater', 'העברת התמונה אחרי')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
