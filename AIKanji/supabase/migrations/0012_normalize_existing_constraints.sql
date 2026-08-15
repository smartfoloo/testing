update public.participant_constraints
set normalized_value = jsonb_build_object(
  'tags', jsonb_build_array(normalized_value->>'diet')
)
where normalized_type = 'dietary'
  and normalized_value ? 'diet';

update public.participant_constraints
set normalized_value = jsonb_build_object(
  'allergens', jsonb_build_array(normalized_value->>'allergen')
)
where normalized_type = 'allergy'
  and normalized_value ? 'allergen';

update public.participant_constraints
set normalized_value = jsonb_build_object(
  'tags', jsonb_build_array(normalized_value->>'atmosphere')
)
where normalized_type = 'atmosphere'
  and normalized_value ? 'atmosphere';

update public.participant_constraints
set normalized_value = jsonb_build_object(
  'include', jsonb_build_array(normalized_value->>'cuisine'),
  'exclude', '[]'::jsonb
)
where normalized_type = 'cuisine'
  and normalized_value ? 'cuisine';
