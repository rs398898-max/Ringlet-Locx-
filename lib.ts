import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string;
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
export const configured = Boolean(url && anon && !url.includes('YOUR_PROJECT'));
export const supabase = createClient(configured ? url : 'https://example.supabase.co', configured ? anon : 'placeholder-key');
export type Product = {
  id: string; name: string; model_number: string; category: string; description: string;
  mrp: number; selling_price: number; wholesale_price: number; min_wholesale_qty: number;
  stock: number; images: string[]; features: string[]; specifications: Record<string,string>;
  active: boolean; created_at?: string;
};
export type Profile = { id: string; full_name: string; phone: string; role: 'customer'|'dealer'|'admin'; dealer_approved: boolean };
export const money = (n: number) => new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR',maximumFractionDigits:0}).format(n || 0);
