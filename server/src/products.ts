type Product = {code: string; name: string; url: string; script: string};

export async function listProducts(db: D1Database) {
  const rows = await db.prepare("SELECT code,name,url FROM products WHERE enabled=1 ORDER BY code").all<Omit<Product,"script">>();
  return rows.results;
}

export async function productByCode(db: D1Database, code: unknown) {
  if (typeof code !== "string") return null;
  return db.prepare("SELECT code,name,url,script FROM products WHERE code=? AND enabled=1").bind(code).first<Product>();
}

export function describeProduct(product: Product, serviceOrigin: string) {
  return {
    code: product.code,
    name: product.name,
    url: product.url,
    origin: new URL(product.url).origin,
    script_url: new URL(product.script, serviceOrigin).href
  };
}
