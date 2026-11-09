-- Run in Supabase SQL Editor. This creates the Ringlet Locx store schema.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '', phone text not null default '',
  role text not null default 'customer' check (role in ('customer','dealer','admin')),
  dealer_approved boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,full_name) values(new.id,coalesce(new.raw_user_meta_data->>'full_name','')) on conflict(id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

-- Prevent customers from changing their own role or dealer approval flag.
create or replace function public.protect_profile_role() returns trigger language plpgsql as $$
begin
  if auth.role() <> 'service_role' then
    new.role := old.role;
    new.dealer_approved := old.dealer_approved;
  end if;
  return new;
end; $$;
drop trigger if exists protect_profile_role_trigger on public.profiles;
create trigger protect_profile_role_trigger before update on public.profiles for each row execute function public.protect_profile_role();

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(), name text not null, model_number text not null unique,
  category text not null, description text not null default '', mrp numeric(12,2) not null default 0 check(mrp>=0),
  selling_price numeric(12,2) not null check(selling_price>=0), wholesale_price numeric(12,2) not null default 0 check(wholesale_price>=0),
  min_wholesale_qty integer not null default 1 check(min_wholesale_qty>=1), stock integer not null default 0 check(stock>=0),
  images text[] not null default '{}', features text[] not null default '{}', specifications jsonb not null default '{}',
  active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
  customer_name text not null, phone text not null, address text not null, city text not null, pincode text not null,
  subtotal numeric(12,2) not null, shipping_charge numeric(12,2) not null default 0, total numeric(12,2) not null,
  payment_method text not null check(payment_method in ('COD','RAZORPAY')), payment_status text not null default 'PENDING',
  payment_id text, razorpay_order_id text, status text not null default 'Confirmed' check(status in ('Pending','Confirmed','Processing','Shipped','Delivered','Cancelled')),
  created_at timestamptz not null default now()
);
create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null, product_name text not null, model_number text not null,
  quantity integer not null check(quantity>0), unit_price numeric(12,2) not null, line_total numeric(12,2) not null
);

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=auth.uid() and role='admin');
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon,authenticated;

drop policy if exists "profiles read self or admin" on public.profiles;
create policy "profiles read self or admin" on public.profiles for select to authenticated using (id=auth.uid() or public.is_admin());
drop policy if exists "profiles update self" on public.profiles;
create policy "profiles update self" on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products for select to anon,authenticated using(active or public.is_admin());
drop policy if exists "admin manage products" on public.products;
create policy "admin manage products" on public.products for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "users read own orders or admin" on public.orders;
create policy "users read own orders or admin" on public.orders for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists "admin update orders" on public.orders;
create policy "admin update orders" on public.orders for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "users read own order items" on public.order_items;
create policy "users read own order items" on public.order_items for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and (o.user_id=auth.uid() or public.is_admin())));

-- Private server-side RPC: only the Edge Function service role can call this.
create or replace function public.finalize_store_order(
  p_user_id uuid, p_customer jsonb, p_items jsonb, p_method text, p_payment_status text,
  p_payment_id text default null, p_razorpay_order_id text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_order_id uuid; v_subtotal numeric(12,2):=0; v_is_dealer boolean:=false; v_item jsonb; v_product public.products%rowtype; v_price numeric(12,2); v_qty integer;
begin
  select (role='dealer' and dealer_approved) into v_is_dealer from public.profiles where id=p_user_id;
  if v_is_dealer is null then v_is_dealer:=false; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::integer;
    if v_qty<1 then raise exception 'Invalid quantity'; end if;
    select * into v_product from public.products where id=(v_item->>'product_id')::uuid and active=true for update;
    if not found then raise exception 'A product is unavailable'; end if;
    if v_product.stock < v_qty then raise exception 'Insufficient stock for %',v_product.name; end if;
    if v_is_dealer then
      if v_qty < v_product.min_wholesale_qty then raise exception 'Minimum wholesale quantity for % is %',v_product.name,v_product.min_wholesale_qty; end if;
      v_price:=v_product.wholesale_price;
    else v_price:=v_product.selling_price; end if;
    v_subtotal:=v_subtotal+(v_price*v_qty);
  end loop;
  if v_subtotal<=0 then raise exception 'Order total must be greater than zero'; end if;
  insert into public.orders(user_id,customer_name,phone,address,city,pincode,subtotal,shipping_charge,total,payment_method,payment_status,payment_id,razorpay_order_id,status)
  values(p_user_id,p_customer->>'name',p_customer->>'phone',p_customer->>'address',p_customer->>'city',p_customer->>'pincode',v_subtotal,0,v_subtotal,p_method,p_payment_status,p_payment_id,p_razorpay_order_id,case when p_payment_status='PAID' then 'Confirmed' else 'Pending' end) returning id into v_order_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products where id=(v_item->>'product_id')::uuid for update;
    v_price:=case when v_is_dealer then v_product.wholesale_price else v_product.selling_price end;
    insert into public.order_items(order_id,product_id,product_name,model_number,quantity,unit_price,line_total)
    values(v_order_id,v_product.id,v_product.name,v_product.model_number,v_qty,v_price,v_price*v_qty);
    update public.products set stock=stock-v_qty,updated_at=now() where id=v_product.id;
  end loop;
  return v_order_id;
end; $$;
revoke all on function public.finalize_store_order(uuid,jsonb,jsonb,text,text,text,text) from public,anon,authenticated;
grant execute on function public.finalize_store_order(uuid,jsonb,jsonb,text,text,text,text) to service_role;

-- Create a public bucket for product photos. Only admins may upload/delete; images are public to display.
insert into storage.buckets(id,name,public) values('product-images','product-images',true) on conflict(id) do nothing;
drop policy if exists "public view product images" on storage.objects;
create policy "public view product images" on storage.objects for select using(bucket_id='product-images');
drop policy if exists "admin upload product images" on storage.objects;
create policy "admin upload product images" on storage.objects for insert to authenticated with check(bucket_id='product-images' and public.is_admin());
drop policy if exists "admin delete product images" on storage.objects;
create policy "admin delete product images" on storage.objects for delete to authenticated using(bucket_id='product-images' and public.is_admin());
