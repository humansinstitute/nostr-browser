import http from 'node:http';
http.createServer((req,res)=>{
 console.log(req.method, req.url, req.headers.origin);
 res.setHeader('Access-Control-Allow-Origin', 'https://example.com');
 res.setHeader('Access-Control-Allow-Headers', 'authorization');
 res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
 res.setHeader('Access-Control-Allow-Private-Network', 'true');
 res.end(req.method === 'OPTIONS' ? '' : 'loopback-ok');
}).listen(47839,'127.0.0.1');
