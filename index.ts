import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';

const cors={ 'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS' };
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}});
const enc=new TextEncoder();
async function hmacHex(secret:string,message:string){const key=await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);const sig=await crypto.subtle.sign('HMAC',key,enc.encode(message));return [...new Uint8Array(sig)].map(b=>b.toString(16).padStart(2,'0')).join('');}
function safeEqual(a:string,b:string){if(a.length!==b.length)return false;let out=0;for(let i=0;i<a.length;i++)out|=a.charCodeAt(i)^b.charCodeAt(i);return out===0;}
serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  try{
    const url=Deno.env.get('SUPABASE_URL')!, anon=Deno.env.get('SUPABASE_ANON_KEY')!, service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth=req.headers.get('Authorization');if(!auth)return json({error:'Unauthorized'},401);
    const userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}});const {data:{user},error:userErr}=await userClient.auth.getUser();if(userErr||!user)return json({error:'Unauthorized'},401);
    const admin=createClient(url,service);const body=await req.json();
    if(body.action==='verify'){
      const keySecret=Deno.env.get('RAZORPAY_KEY_SECRET')!;const sig=String(body.razorpay_signature||'');const orderId=String(body.razorpay_order_id||body.order_id||'');const paymentId=String(body.razorpay_payment_id||'');
      const expected=await hmacHex(keySecret,`${orderId}|${paymentId}`);if(!safeEqual(expected,sig))return json({error:'Invalid payment signature'},400);
      const paymentRes=await fetch(`https://api.razorpay.com/v1/payments/${paymentId}`,{headers:{Authorization:`Basic ${btoa(`${Deno.env.get('RAZORPAY_KEY_ID')}:${keySecret}`)}`}});
      const payment=await paymentRes.json();if(!paymentRes.ok||payment.status!=='captured'||payment.order_id!==orderId)return json({error:'Payment is not captured'},400);
      const {data:profile}=await admin.from('profiles').select('role,dealer_approved').eq('id',user.id).single();
      let expectedAmount=0;
      for(const item of body.items||[]){const {data:p,error:productError}=await admin.from('products').select('*').eq('id',item.product_id).eq('active',true).single();if(productError||!p)return json({error:'A product is no longer available'},400);const qty=Number(item.quantity);if(!Number.isInteger(qty)||qty<1||p.stock<qty)return json({error:'Product stock changed. Please retry checkout.'},400);const dealer=profile?.role==='dealer'&&profile?.dealer_approved;if(dealer&&qty<p.min_wholesale_qty)return json({error:`Minimum wholesale quantity for ${p.name} is ${p.min_wholesale_qty}`},400);expectedAmount+=Number(dealer?p.wholesale_price:p.selling_price)*qty;}
      if(Number(payment.amount)!==Math.round(expectedAmount*100))return json({error:'Product prices changed during checkout. Please contact support before placing another order.'},409);
      const {data:order,error}=await admin.rpc('finalize_store_order',{p_user_id:user.id,p_customer:body.customer,p_items:body.items,p_method:'RAZORPAY',p_payment_status:'PAID',p_payment_id:paymentId,p_razorpay_order_id:orderId});
      if(error)throw error;return json({success:true,order_id:order});
    }
    const {data:profile}=await admin.from('profiles').select('role,dealer_approved').eq('id',user.id).single();
    const items=body.items;if(!Array.isArray(items)||items.length===0) return json({error:'Cart is empty'},400);
    let amount=0;
    for(const item of items){const {data:p,error}=await admin.from('products').select('*').eq('id',item.product_id).eq('active',true).single();if(error||!p)return json({error:'A product is unavailable'},400);const qty=Number(item.quantity);if(!Number.isInteger(qty)||qty<1||p.stock<qty)return json({error:`Invalid quantity or insufficient stock for ${p.name}`},400);const dealer=profile?.role==='dealer'&&profile?.dealer_approved;if(dealer&&qty<p.min_wholesale_qty)return json({error:`Minimum wholesale quantity for ${p.name} is ${p.min_wholesale_qty}`},400);amount+=Number(dealer?p.wholesale_price:p.selling_price)*qty;}
    if(!body.customer?.name||!body.customer?.phone||!body.customer?.address||!body.customer?.city||!body.customer?.pincode)return json({error:'Delivery details are incomplete'},400);
    if(body.method==='COD'){
      const {data:order,error}=await admin.rpc('finalize_store_order',{p_user_id:user.id,p_customer:body.customer,p_items:items,p_method:'COD',p_payment_status:'PENDING',p_payment_id:null,p_razorpay_order_id:null});if(error)throw error;return json({success:true,order_id:order});
    }
    const keyId=Deno.env.get('RAZORPAY_KEY_ID')!,secret=Deno.env.get('RAZORPAY_KEY_SECRET')!;
    const r=await fetch('https://api.razorpay.com/v1/orders',{method:'POST',headers:{Authorization:`Basic ${btoa(`${keyId}:${secret}`)}`,'Content-Type':'application/json'},body:JSON.stringify({amount:Math.round(amount*100),currency:'INR',receipt:`rlx_${user.id.slice(0,8)}_${Date.now()}`})});
    const result=await r.json();if(!r.ok)return json({error:result.error?.description||'Unable to create payment order'},400);
    return json({razorpay_order_id:result.id,amount:result.amount,currency:result.currency});
  }catch(e){console.error(e);return json({error:e instanceof Error?e.message:'Unexpected checkout error'},500);}
});
