revoke execute on function public.check_email_availability(text, uuid) from public;
revoke execute on function public.check_email_availability(text, uuid) from anon;

revoke execute on function public.get_promo_code_details(text) from public;
revoke execute on function public.get_promo_code_details(text) from anon;
