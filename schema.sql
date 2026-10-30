-- JobBoost : à coller dans Supabase > SQL Editor > Run
create table profiles(id uuid primary key references auth.users on delete cascade,name text,phone text unique,bal bigint not null default 0,role text not null default 'client' check(role in('client','admin')),num serial,at timestamptz default now());
create table services(id serial primary key,plat text not null,em text default '⭐',name text not null,price int not null,qmin int default 10,qmax int default 100000,active boolean default true);
create table service_costs(sid int primary key references services on delete cascade,cost int not null default 0);
create table orders(id serial primary key,uid uuid references profiles(id),sid int,sname text,link text,qty int,price int,cost int,st int default 0,at timestamptz default now());
create table deposits(id serial primary key,uid uuid references profiles(id),amount int check(amount>=500),method text,ref text,st int default 0,at timestamptz default now());
create table pay_methods(id serial primary key,name text,num text default '');
create table settings(id int primary key default 1 check(id=1),name text default 'JobBoost',color text default '#10b981',wa text default '');

create function is_admin() returns boolean language sql security definer stable set search_path=public as $$select exists(select 1 from profiles where id=auth.uid() and role='admin')$$;

create function new_user() returns trigger language plpgsql security definer set search_path=public as $$begin
insert into profiles(id,name,phone) values(new.id,new.raw_user_meta_data->>'name',new.raw_user_meta_data->>'phone');return new;end$$;
create trigger on_signup after insert on auth.users for each row execute function new_user();

create function place_order(p_sid int,p_link text,p_qty int) returns int language plpgsql security definer set search_path=public as $$
declare s services;c int;pr int;nid int;
begin
select * into s from services where id=p_sid and active;
if not found then raise exception 'Service indisponible';end if;
if p_qty<s.qmin or p_qty>s.qmax then raise exception 'Quantité invalide';end if;
if length(trim(p_link))<3 then raise exception 'Lien invalide';end if;
pr:=round(s.price*p_qty/1000.0);
select cost into c from service_costs where sid=s.id;
update profiles set bal=bal-pr where id=auth.uid() and bal>=pr;
if not found then raise exception 'Solde insuffisant';end if;
insert into orders(uid,sid,sname,link,qty,price,cost) values(auth.uid(),s.id,s.plat||' · '||s.name,trim(p_link),p_qty,pr,round(coalesce(c,0)*p_qty/1000.0)) returning id into nid;
return nid;end$$;

create function set_order_status(p_id int,p_st int) returns void language plpgsql security definer set search_path=public as $$
declare o orders;
begin
if not is_admin() then raise exception 'Interdit';end if;
select * into o from orders where id=p_id for update;
if o.st=4 then raise exception 'Commande déjà annulée';end if;
if p_st=4 then update profiles set bal=bal+o.price where id=o.uid;end if;
update orders set st=p_st where id=p_id;end$$;

create function review_deposit(p_id int,p_st int) returns void language plpgsql security definer set search_path=public as $$
declare d deposits;
begin
if not is_admin() then raise exception 'Interdit';end if;
select * into d from deposits where id=p_id and st=0 for update;
if not found then return;end if;
if p_st=1 then update profiles set bal=bal+d.amount where id=d.uid;end if;
update deposits set st=p_st where id=p_id;end$$;

create function adjust_balance(p_uid uuid,p_amt int) returns void language plpgsql security definer set search_path=public as $$
begin if not is_admin() then raise exception 'Interdit';end if;
update profiles set bal=bal+p_amt where id=p_uid;end$$;

-- Sécurité (RLS) : le client ne peut jamais modifier son solde ni son rôle
alter table profiles enable row level security;alter table services enable row level security;alter table service_costs enable row level security;
alter table orders enable row level security;alter table deposits enable row level security;alter table pay_methods enable row level security;alter table settings enable row level security;
create policy r on profiles for select using(id=auth.uid() or is_admin());
create policy r on orders for select using(uid=auth.uid() or is_admin());
create policy r on deposits for select using(uid=auth.uid() or is_admin());
create policy i on deposits for insert with check(uid=auth.uid() and st=0);
create policy r on services for select using(true);
create policy w on services for all using(is_admin()) with check(is_admin());
create policy r on pay_methods for select using(true);
create policy w on pay_methods for all using(is_admin()) with check(is_admin());
create policy r on settings for select using(true);
create policy w on settings for all using(is_admin()) with check(is_admin());
create policy a on service_costs for all using(is_admin()) with check(is_admin());

-- Données de départ (numéros de paiement à remplir ensuite dans l'admin)
insert into settings(id) values(1);
insert into pay_methods(name) values('Orange Money'),('Airtel Money'),('M-Pesa'),('Afrimoney');
insert into services(plat,em,name,price,qmin,qmax) values('Facebook','👍','Réactions J''aime',156,10,100000),('Facebook','👥','Abonnés Page',174,50,100000),('TikTok','👁️','Vues vidéo',198,100,1000000),('TikTok','❤️','Likes',197,10,100000),('Instagram','👥','Abonnés',300,50,100000),('YouTube','👁️','Vues vidéo',3000,100,100000);

-- APRÈS avoir créé les 2 comptes admin dans le site, remplacez les numéros et exécutez :
-- update profiles set role='admin' where phone in ('0800000001','0800000002');

-- AJOUT v2 (si vous avez déjà exécuté le schéma, exécutez seulement ce bloc) : champ "Restant" des commandes
alter table orders add column if not exists rest int;
create or replace function set_rest(p_id int,p_rest int) returns void language plpgsql security definer set search_path=public as $$
begin if not is_admin() then raise exception 'Interdit';end if;
update orders set rest=p_rest,st=case when p_rest=0 then 3 when st<2 then 2 else st end where id=p_id and st<>4;end$$;

-- AJOUT v3 : historique des mouvements de solde (exécutez ce bloc après le v2)
create table transactions(id serial primary key,uid uuid references profiles(id) on delete cascade,amount int not null,label text,at timestamptz default now());
alter table transactions enable row level security;
create policy r on transactions for select using(uid=auth.uid() or is_admin());

create or replace function place_order(p_sid int,p_link text,p_qty int) returns int language plpgsql security definer set search_path=public as $$
declare s services;c int;pr int;nid int;
begin
select * into s from services where id=p_sid and active;
if not found then raise exception 'Service indisponible';end if;
if p_qty<s.qmin or p_qty>s.qmax then raise exception 'Quantité invalide';end if;
if length(trim(p_link))<3 then raise exception 'Lien invalide';end if;
pr:=round(s.price*p_qty/1000.0);
select cost into c from service_costs where sid=s.id;
update profiles set bal=bal-pr where id=auth.uid() and bal>=pr;
if not found then raise exception 'Solde insuffisant';end if;
insert into orders(uid,sid,sname,link,qty,price,cost) values(auth.uid(),s.id,s.plat||' · '||s.name,trim(p_link),p_qty,pr,round(coalesce(c,0)*p_qty/1000.0)) returning id into nid;
insert into transactions(uid,amount,label) values(auth.uid(),-pr,'Commande n°'||nid);
return nid;end$$;

create or replace function set_order_status(p_id int,p_st int) returns void language plpgsql security definer set search_path=public as $$
declare o orders;
begin
if not is_admin() then raise exception 'Interdit';end if;
select * into o from orders where id=p_id for update;
if o.st=4 then raise exception 'Commande déjà annulée';end if;
if p_st=4 then update profiles set bal=bal+o.price where id=o.uid;insert into transactions(uid,amount,label) values(o.uid,o.price,'Remboursement commande n°'||o.id);end if;
update orders set st=p_st where id=p_id;end$$;

create or replace function review_deposit(p_id int,p_st int) returns void language plpgsql security definer set search_path=public as $$
declare d deposits;
begin
if not is_admin() then raise exception 'Interdit';end if;
select * into d from deposits where id=p_id and st=0 for update;
if not found then return;end if;
if p_st=1 then update profiles set bal=bal+d.amount where id=d.uid;insert into transactions(uid,amount,label) values(d.uid,d.amount,'Recharge '||d.method);end if;
update deposits set st=p_st where id=p_id;end$$;

create or replace function adjust_balance(p_uid uuid,p_amt int) returns void language plpgsql security definer set search_path=public as $$
begin if not is_admin() then raise exception 'Interdit';end if;
update profiles set bal=bal+p_amt where id=p_uid;
insert into transactions(uid,amount,label) values(p_uid,p_amt,'Ajustement par l''administrateur');end$$;
