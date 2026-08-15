-- Compatibility for the existing domain safety test's scratch event. New app
-- callers use the full organizer-aware signature from 0007.
create or replace function public.fn_create_event(p_name text)
returns jsonb
language sql security definer
set search_path = ''
as $$
  select public.fn_create_event(p_name, 'Organizer', 'office', null, 'balanced');
$$;
