# Ringlet Locx Store

A React + TypeScript storefront starter for Ringlet Locx with Supabase authentication/database/storage and a server-side Razorpay checkout Edge Function.

## Included
- Responsive product storefront, category filters and search
- Email/password customer sign-up and sign-in
- Admin-only product create/edit/delete and product image uploads
- Retail/dealer price selection (dealer role must be approved by an admin)
- Cart, delivery details, Razorpay online checkout and Cash on Delivery
- Server-side Razorpay signature + captured-payment verification
- Orders saved in Supabase, order history and admin status updates
- Row Level Security policies and a server-only order-finalization RPC

## 1. Create Supabase project
1. Create a project at https://supabase.com.
2. Open **SQL Editor** and run `supabase/schema.sql`.
3. In **Authentication → Providers**, enable Email. For quick testing you may turn off email confirmation; enable it for production.
4. In **Project Settings → API**, copy Project URL and anon/public key into `.env` (see `.env.example`). Never put the service-role key in frontend code.

## 2. Create the first admin
1. Sign up through the app with the email you want to use as admin.
2. In Supabase SQL Editor, run this query with that account's email:

```sql
update public.profiles p
set role = 'admin'
from auth.users u
where p.id = u.id and u.email = 'YOUR_ADMIN_EMAIL';
```

The profile role is deliberately not user-editable. To approve a dealer, update their profile from the SQL editor, e.g.:

```sql
update public.profiles p set role='dealer', dealer_approved=true
from auth.users u where p.id=u.id and u.email='DEALER_EMAIL';
```

## 3. Configure Razorpay + Edge Function
1. Create/get API keys from your Razorpay dashboard. Start with test keys.
2. Install the Supabase CLI and log in: https://supabase.com/docs/guides/cli.
3. Link your project: `supabase link --project-ref YOUR_PROJECT_REF`.
4. Set server secrets (do not add these to `.env`):

```bash
supabase secrets set RAZORPAY_KEY_ID=rzp_test_xxxxx RAZORPAY_KEY_SECRET=your_secret
```

5. Deploy the function:

```bash
supabase functions deploy checkout
```

6. Put the matching public Razorpay Key ID in `.env` as `VITE_RAZORPAY_KEY_ID=rzp_test_xxxxx`.

The Edge Function uses the Supabase service-role key from its server environment. Do not expose that key to the browser. For production, configure Razorpay webhooks as an additional reconciliation mechanism and test refunds, failures and disputes.

## 4. Run locally

```bash
cp .env.example .env
# Edit .env with your project URL, anon key and Razorpay Key ID
npm install
npm run dev
```

For a production build:

```bash
npm run build
```

Deploy the generated `dist/` directory to Vercel, Netlify or another static host. Set the same `VITE_` environment variables in the hosting provider before building.

## Important notes before going live
- This is a functional starter, not a substitute for a production security review. Test with a separate Supabase project and Razorpay test keys first.
- Product catalog starts empty intentionally. Add your real Ringlet Locx SKUs, verified product photos, descriptions, prices, warranty terms and stock through the Admin panel. Do not publish placeholder or unverified specifications.
- The app currently uses email/password authentication. SMS OTP, dealer application workflow, shipping carrier integration, GST invoice generation, refunds, and notification/email automation are not included.
- Shipping is currently set to ₹0. Configure shipping/tax calculations before accepting live orders.
- COD orders are recorded as pending payment and confirmed orders deduct stock. Set your own COD verification/fulfilment process.
- Use HTTPS, enable Supabase email confirmation, configure rate limits and backups, and review RLS policies before launch.
