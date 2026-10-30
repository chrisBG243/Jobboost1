-- JobBoost : à coller dans Supabase > SQL Editor > Run
create table profiles(id uuid primary key references auth.users on delete cascade,name text,phone text unique,bal bigint not null default 0,role text not null default 'client' check(role in('client','admin')),num serial,at timestamptz default now());
create table services(id serial primary key,plat text not null,em text default '⭐',name text not null,price int not null,qmin int default 10,qmax int default 100000,active boolean default true);
create table service_costs(sid int primary key references services on delete cascade,cost int not null default 0);
create table orders(id serial primary key,uid uuid references profiles(id),sid int,sname text,link text,qty int,price int,cost int,st int default 0,at timestamptz default now());
create table deposits(id serial primary key,uid uuid references profiles(id),amount int check(amount>=500),method text,ref text,st int default 0,at timestamptz default now());
create table pay_methods(id serial primary key,name text,num text default '');
create table settings(id int primary key default 1 check(id=1),name text default 'FastBoost',color text default '#10b981',wa text default '');

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

-- AJOUT v4 : page publique, populaires, garantie, parrainage, codes promo, USD (exécutez ce bloc après le v3)
alter table settings add column if not exists email text default '',add column if not exists wa_channel text default '',add column if not exists usd_rate int default 2800,add column if not exists ref_pct int default 5;
alter table services add column if not exists best boolean default false;
alter table profiles add column if not exists code text unique,add column if not exists ref_by uuid references profiles(id);
update profiles set code=upper(substr(md5(id::text),1,6)) where code is null;
create table refills(id serial primary key,oid int references orders(id) on delete cascade,uid uuid references profiles(id),st int default 0,at timestamptz default now());
create table promos(code text primary key,amount int not null,max_uses int default 100,used int default 0,active boolean default true);
create table promo_uses(uid uuid references profiles(id) on delete cascade,code text,primary key(uid,code));
alter table refills enable row level security;alter table promos enable row level security;alter table promo_uses enable row level security;
create policy r on refills for select using(uid=auth.uid() or is_admin());
create policy w on refills for update using(is_admin());
create policy a on promos for all using(is_admin()) with check(is_admin());

create or replace function new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare rb uuid;
begin
select id into rb from profiles where code=upper(trim(new.raw_user_meta_data->>'ref'));
insert into profiles(id,name,phone,code,ref_by) values(new.id,new.raw_user_meta_data->>'name',new.raw_user_meta_data->>'phone',upper(substr(md5(new.id::text),1,6)),rb);
return new;end$$;

create function request_refill(p_oid int) returns void language plpgsql security definer set search_path=public as $$
declare o orders;
begin select * into o from orders where id=p_oid and uid=auth.uid();
if not found or o.st<>3 then raise exception 'Commande non éligible';end if;
if o.at<now()-interval '30 days' then raise exception 'Garantie de 30 jours expirée';end if;
if exists(select 1 from refills where oid=p_oid and st=0) then raise exception 'Demande déjà envoyée';end if;
insert into refills(oid,uid) values(p_oid,auth.uid());end$$;

create function redeem_promo(p_code text) returns int language plpgsql security definer set search_path=public as $$
declare p promos;
begin select * into p from promos where code=upper(trim(p_code)) and active and used<max_uses for update;
if not found then raise exception 'Code invalide ou épuisé';end if;
begin insert into promo_uses(uid,code) values(auth.uid(),p.code);
exception when unique_violation then raise exception 'Code déjà utilisé';end;
update promos set used=used+1 where code=p.code;
update profiles set bal=bal+p.amount where id=auth.uid();
insert into transactions(uid,amount,label) values(auth.uid(),p.amount,'Code promo '||p.code);
return p.amount;end$$;

create or replace function review_deposit(p_id int,p_st int) returns void language plpgsql security definer set search_path=public as $$
declare d deposits;rb uuid;pc int;b int;
begin
if not is_admin() then raise exception 'Interdit';end if;
select * into d from deposits where id=p_id and st=0 for update;
if not found then return;end if;
if p_st=1 then
 update profiles set bal=bal+d.amount where id=d.uid;
 insert into transactions(uid,amount,label) values(d.uid,d.amount,'Recharge '||d.method);
 select ref_by into rb from profiles where id=d.uid;
 select ref_pct into pc from settings where id=1;
 if rb is not null and coalesce(pc,0)>0 and not exists(select 1 from deposits where uid=d.uid and st=1) then
  b:=round(d.amount*pc/100.0);
  update profiles set bal=bal+b where id=rb;
  insert into transactions(uid,amount,label) values(rb,b,'Bonus parrainage');
 end if;
end if;
update deposits set st=p_st where id=p_id;end$$;

-- Nouveaux services d'exemple (ajustez les prix dans Admin > Tarifs)
insert into services(plat,em,name,price,qmin,qmax) values('Spotify','🎧','Écoutes',1500,100,1000000),('Spotify','👥','Abonnés artiste',2500,50,100000),('Telegram','👥','Membres canal',1200,50,100000),('X','👥','Abonnés',2800,50,50000),('X','❤️','Likes',900,10,50000),('TikTok','💬','Commentaires',9000,5,5000),('Instagram','↗️','Partages',700,10,100000),('Facebook','↗️','Partages',650,10,100000);
update services set best=true where (plat,name) in (('TikTok','Likes'),('TikTok','Vues vidéo'),('Facebook','Réactions J''aime'));

-- AJOUT v5 : nouveau nom du site
update settings set name='FastBoost' where id=1;
