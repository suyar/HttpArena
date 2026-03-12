const datasetPath = Deno.env.get("DATASET_PATH") || "/data/dataset.json";
let datasetItems: any[] | undefined;

try {
    datasetItems = JSON.parse(Deno.readTextFileSync(datasetPath));
} catch { /* dataset not available */ }

const PLAIN = { "content-type": "text/plain", "server": "deno" };

function sumQuery(url: string, pathEnd: number): number {
    const q = url.indexOf("?", pathEnd);
    if (q === -1) return 0;
    let sum = 0;
    const qs = url.slice(q + 1);
    let i = 0;
    while (i < qs.length) {
        const eq = qs.indexOf("=", i);
        if (eq === -1) break;
        let amp = qs.indexOf("&", eq);
        if (amp === -1) amp = qs.length;
        const n = parseInt(qs.slice(eq + 1, amp), 10);
        if (n === n) sum += n;
        i = amp + 1;
    }
    return sum;
}

export default {
    async fetch(req: Request): Promise<Response> {
        const url = req.url;
        const pathStart = url.indexOf("/", 8);
        const queryStart = url.indexOf("?", pathStart);
        const path = queryStart === -1 ? url.slice(pathStart) : url.slice(pathStart, queryStart);

        if (path === "/pipeline") {
            return new Response("ok", { headers: PLAIN });
        }

        if (path === "/json") {
            if (datasetItems) {
                const items = datasetItems.map((d: any) => ({
                    id: d.id, name: d.name, category: d.category,
                    price: d.price, quantity: d.quantity, active: d.active,
                    tags: d.tags, rating: d.rating,
                    total: Math.round(d.price * d.quantity * 100) / 100,
                }));
                const body = JSON.stringify({ items, count: items.length });
                return new Response(body, {
                    headers: { "content-type": "application/json", "server": "deno" },
                });
            }
            return new Response("No dataset", { status: 500 });
        }

        // /baseline11
        let sum = sumQuery(url, pathStart);
        if (req.method === "POST") {
            const body = (await req.text()).trim();
            const n = parseInt(body, 10);
            if (n === n) sum += n;
        }
        return new Response(String(sum), { headers: PLAIN });
    },
};
