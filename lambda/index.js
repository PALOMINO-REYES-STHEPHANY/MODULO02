// index.js - Lambda for GET /stats/{codigo}
const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB.DocumentClient();

function isValidDateStr(s) {
  return /^\d{4}-\d{2}-\d{2}$/.test(s);
}

function dateRangeArray(fromStr, toStr) {
  const arr = [];
  let cur = new Date(fromStr);
  const end = new Date(toStr);
  while (cur <= end) {
    arr.push(cur.toISOString().slice(0,10));
    cur.setDate(cur.getDate() + 1);
  }
  return arr;
}

exports.handler = async (event) => {
  try {
    const code = event.pathParameters && event.pathParameters.codigo;
    if (!code) {
      return { statusCode: 400, body: JSON.stringify({ message: "Se requiere path parameter {codigo}" }) };
    }

    const qs = event.queryStringParameters || {};
    const from = qs.from;
    const to = qs.to;

    const today = new Date();
    const defaultTo = today.toISOString().slice(0,10);
    const defaultFrom = new Date(today.getTime() - 29*24*60*60*1000).toISOString().slice(0,10);

    const qfrom = from && isValidDateStr(from) ? from : defaultFrom;
    const qto = to && isValidDateStr(to) ? to : defaultTo;

    if (qfrom > qto) {
      return { statusCode: 400, body: JSON.stringify({ message: "'from' debe ser <= 'to' (YYYY-MM-DD)" }) };
    }

    const tableName = process.env.VISITS_TABLE;
    if (!tableName) {
      return { statusCode: 500, body: JSON.stringify({ message: "VISITS_TABLE no configurada en variables de entorno" }) };
    }

    const params = {
      TableName: tableName,
      KeyConditionExpression: "#c = :code AND #d BETWEEN :from AND :to",
      ExpressionAttributeNames: { "#c": "code", "#d": "date" },
      ExpressionAttributeValues: { ":code": code, ":from": qfrom, ":to": qto }
    };

    const resp = await ddb.query(params).promise();
    const items = resp.Items || [];

    const mapByDate = {};
    for (const it of items) {
      mapByDate[it.date] = (mapByDate[it.date] || 0) + (it.count || 0);
    }

    const seriesDates = dateRangeArray(qfrom, qto);
    const series = seriesDates.map(d => ({ date: d, count: mapByDate[d] || 0 }));
    const total = series.reduce((s, x) => s + x.count, 0);

    const result = { code, from: qfrom, to: qto, total, series, rawItemsCount: items.length };
    return { statusCode: 200, body: JSON.stringify(result), headers: { "Content-Type": "application/json" } };

  } catch (err) {
    console.error("Error stats lambda:", err);
    return { statusCode: 500, body: JSON.stringify({ message: "Error interno", error: String(err) }) };
  }
};