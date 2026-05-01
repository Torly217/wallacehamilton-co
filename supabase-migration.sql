-- The Way (theway.world / wallacehamilton.co) — Supabase migration
-- Run in Supabase SQL Editor on the shared Neothink ecosystem project
-- (https://oiajckhzuhdiokhjkjnc.supabase.co).
--
-- Adds:
--   1. way_subscribers table + submit_way_subscribe RPC
--   2. way_contacts table + submit_way_contact RPC
--   3. Email notification triggers on both tables (Resend via pg_net)
--
-- Mirrors the NTS pattern in supabase-setup.sql / supabase-contact-migration.sql:
--   * Anon key callers can ONLY call the RPCs (no direct table access)
--   * RPCs are SECURITY DEFINER and validate input
--   * Each insert fires a trigger that emails wallace@neothink.com via Resend
--
-- IMPORTANT: This repo is PUBLIC. Before running this migration, replace
-- the two `RESEND_API_KEY_HERE` placeholders below with the actual Resend
-- API key (the same one used in supabase-contact-migration.sql for NTS).
-- The key never gets committed; you paste it once into the Supabase SQL
-- Editor when running this migration.
--
-- A safer long-term option: store the key in a Supabase Vault secret
-- (vault.create_secret) and reference it via vault.read_secret instead
-- of inlining. Worth doing on a future cleanup pass across all three
-- Way / NTS migration files.

-- ============================================================================
-- 1. SUBSCRIBERS
-- ============================================================================

create table if not exists public.way_subscribers (
  id uuid primary key default gen_random_uuid(),
  submitted_at timestamptz not null default now(),
  source text default 'theway.world',

  email text not null,

  status text default 'new' check (status in ('new', 'engaged', 'unsubscribed', 'archived')),
  notes text
);

create index if not exists way_subscribers_submitted_at_idx
  on public.way_subscribers (submitted_at desc);
create index if not exists way_subscribers_email_idx
  on public.way_subscribers (lower(email));
create index if not exists way_subscribers_status_idx
  on public.way_subscribers (status);

alter table public.way_subscribers enable row level security;

create or replace function public.submit_way_subscribe(
  p_email text,
  p_source text default 'theway.world'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_email text;
begin
  v_email := btrim(coalesce(p_email, ''));
  if v_email = '' then raise exception 'email required'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid email'; end if;

  insert into public.way_subscribers (email, source)
  values (lower(v_email), btrim(coalesce(p_source, 'theway.world')))
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_way_subscribe(text, text) from public;
grant execute on function public.submit_way_subscribe(text, text) to anon, authenticated;

-- ============================================================================
-- 2. CONTACT MESSAGES
-- ============================================================================

create table if not exists public.way_contacts (
  id uuid primary key default gen_random_uuid(),
  submitted_at timestamptz not null default now(),
  source text default 'theway.world/contact',

  name text not null,
  email text not null,
  message text not null,

  status text default 'new' check (status in ('new', 'reviewing', 'replied', 'archived')),
  reviewed_by text,
  reviewed_at timestamptz,
  internal_notes text
);

create index if not exists way_contacts_submitted_at_idx
  on public.way_contacts (submitted_at desc);
create index if not exists way_contacts_status_idx
  on public.way_contacts (status);

alter table public.way_contacts enable row level security;

create or replace function public.submit_way_contact(
  p_name text,
  p_email text,
  p_message text,
  p_source text default 'theway.world/contact'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_name is null or btrim(p_name) = '' then raise exception 'name required'; end if;
  if p_email is null or btrim(p_email) = '' then raise exception 'email required'; end if;
  if p_message is null or btrim(p_message) = '' then raise exception 'message required'; end if;

  insert into public.way_contacts (name, email, message, source)
  values (btrim(p_name), btrim(p_email), btrim(p_message), btrim(coalesce(p_source, 'theway.world/contact')))
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_way_contact(text, text, text, text) from public;
grant execute on function public.submit_way_contact(text, text, text, text) to anon, authenticated;

-- ============================================================================
-- 3. EMAIL NOTIFICATIONS (Resend via pg_net)
-- Sends an email to wallace@neothink.com on every new submission across
-- both tables. Sender uses the verified auth.neothink.io domain so the
-- existing Resend configuration handles delivery.
-- ============================================================================

create extension if not exists pg_net;

create or replace function public.notify_way_subscribe()
returns trigger
language plpgsql
security definer
as $$
declare
  v_html text;
begin
  v_html := format(
    '<h2 style="font-family:Georgia,serif;color:#0E0E10">New Way Subscriber</h2>'
    '<table style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.6">'
    '<tr><td><strong>Email:</strong></td><td>%s</td></tr>'
    '<tr><td><strong>Source:</strong></td><td>%s</td></tr>'
    '<tr><td><strong>Submitted:</strong></td><td>%s</td></tr>'
    '</table>'
    '<p style="color:#888;font-size:13px;margin-top:24px">Supabase id: %s</p>',
    coalesce(new.email,''), coalesce(new.source,'—'),
    new.submitted_at::text, new.id::text
  );

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer RESEND_API_KEY_HERE',
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', 'The Way <theway@auth.neothink.io>',
      'to', 'wallace@neothink.com',
      'subject', 'New Way subscriber: ' || coalesce(new.email, 'unknown'),
      'html', v_html,
      'reply_to', new.email
    )
  );
  return new;
end;
$$;

create or replace function public.notify_way_contact()
returns trigger
language plpgsql
security definer
as $$
declare
  v_html text;
begin
  v_html := format(
    '<h2 style="font-family:Georgia,serif;color:#0E0E10">New Way Contact Message</h2>'
    '<table style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.6">'
    '<tr><td><strong>Name:</strong></td><td>%s</td></tr>'
    '<tr><td><strong>Email:</strong></td><td>%s</td></tr>'
    '<tr><td><strong>Source:</strong></td><td>%s</td></tr>'
    '<tr><td><strong>Submitted:</strong></td><td>%s</td></tr>'
    '</table>'
    '<h3 style="font-family:Georgia,serif;color:#0E0E10;margin-top:24px">Message</h3>'
    '<div style="font-family:Georgia,serif;font-size:16px;line-height:1.7;color:#333;'
       'border-left:3px solid #c9b68a;padding-left:16px;white-space:pre-wrap">%s</div>'
    '<p style="color:#888;font-size:13px;margin-top:24px">Supabase id: %s</p>',
    coalesce(new.name,''), coalesce(new.email,''), coalesce(new.source,'—'),
    new.submitted_at::text, coalesce(new.message,''), new.id::text
  );

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer RESEND_API_KEY_HERE',
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', 'The Way <theway@auth.neothink.io>',
      'to', 'wallace@neothink.com',
      'subject', 'New Way contact: ' || coalesce(new.name, 'Anonymous'),
      'html', v_html,
      'reply_to', new.email
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_way_subscribe on public.way_subscribers;
create trigger trg_notify_way_subscribe
  after insert on public.way_subscribers
  for each row execute function public.notify_way_subscribe();

drop trigger if exists trg_notify_way_contact on public.way_contacts;
create trigger trg_notify_way_contact
  after insert on public.way_contacts
  for each row execute function public.notify_way_contact();

-- ============================================================================
-- DONE.
-- Verify with:
--   select routine_name from information_schema.routines
--   where routine_schema = 'public' and routine_name like 'submit_way_%';
--
-- Smoke test (run as a logged-in user — anon role can call via the RPC URL):
--   select public.submit_way_subscribe('test@example.com', 'theway.world');
--   select public.submit_way_contact('Test', 'test@example.com', 'Hello.', 'theway.world/contact');
-- ============================================================================
