"""MCP tool server for Qdrant vector database operations."""
import os
from typing import Optional

from fastmcp import FastMCP
from qdrant_client import QdrantClient
from starlette.responses import JSONResponse

QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
PORT = int(os.environ.get("MCP_PORT", "8093"))

mcp = FastMCP("qdrant-mcp")
client = QdrantClient(url=QDRANT_URL)


@mcp.custom_route("/health", methods=["GET"])
async def health(request):
    try:
        collections = client.get_collections()
        return JSONResponse({"status": "ok", "collections": len(collections.collections)})
    except Exception as e:
        return JSONResponse({"status": "error", "detail": str(e)}, status_code=503)


@mcp.tool
def list_collections() -> list[dict]:
    """List all Qdrant collections with point counts."""
    result = client.get_collections()
    out = []
    for c in result.collections:
        info = client.get_collection(c.name)
        out.append({
            "name": c.name,
            "points": info.points_count,
            "vectors_size": info.config.params.vectors.size if hasattr(info.config.params.vectors, "size") else None,
        })
    return out


@mcp.tool
def search(query: str, collection: str, top_k: int = 5) -> list[dict]:
    """Search a Qdrant collection using text. Requires the collection to have a dense vector named 'default'.
    Returns top_k results with scores and payloads."""
    # Qdrant's search requires a vector, not text. We need to embed the query first.
    # Use the local embedding agent at port 8090.
    import json
    import urllib.request

    embed_url = os.environ.get("EMBEDDING_URL", "http://localhost:8090")
    req = urllib.request.Request(
        f"{embed_url}/v1/embeddings",
        data=json.dumps({"model": "nomic-embed-text", "input": query}).encode(),
        method="POST",
    )
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        embed_result = json.loads(resp.read())
    vector = embed_result["data"][0]["embedding"]

    results = client.query_points(
        collection_name=collection,
        query=vector,
        limit=top_k,
        with_payload=True,
    )
    return [
        {"id": str(p.id), "score": p.score, "payload": p.payload}
        for p in results.points
    ]


@mcp.tool
def upsert(text: str, metadata: dict, collection: str, doc_id: Optional[str] = None) -> dict:
    """Embed text and upsert it into a Qdrant collection. Auto-generates an ID if not provided."""
    import json
    import urllib.request
    import uuid

    embed_url = os.environ.get("EMBEDDING_URL", "http://localhost:8090")
    req = urllib.request.Request(
        f"{embed_url}/v1/embeddings",
        data=json.dumps({"model": "nomic-embed-text", "input": text}).encode(),
        method="POST",
    )
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        embed_result = json.loads(resp.read())
    vector = embed_result["data"][0]["embedding"]

    point_id = doc_id or str(uuid.uuid4())
    payload = {**metadata, "text": text}

    from qdrant_client.models import PointStruct
    client.upsert(
        collection_name=collection,
        points=[PointStruct(id=point_id, vector=vector, payload=payload)],
    )
    return {"id": point_id, "collection": collection, "status": "ok"}


if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=PORT)
