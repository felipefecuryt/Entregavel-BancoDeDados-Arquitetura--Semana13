// ============================================================================
// CONTEXTO DELIMITADO: ESTOQUE
// SGBD: MongoDB (NoSQL - Orientado a Documentos)
// Arquivo: produtos.js
// Execucao: mongosh < produtos.js      ou      load("produtos.js") no mongosh
//
// Justificativa da escolha:
//   O catalogo de uma loja e heterogeneo por natureza. Um celular tem tela,
//   bateria, memoria, camera e chipset. Uma camiseta tem cor, tamanho,
//   malha e caimento. Um cabo HDMI tem comprimento e versao.
//   No modelo relacional isso exigiria uma tabela por categoria, ou uma
//   tabela generica chave-valor (EAV) que transforma qualquer consulta em
//   uma pilha de JOINs. No modelo de documentos cada produto carrega o seu
//   proprio formato e o campo "especificacoes" varia livremente de um
//   documento para outro, sem migracao de esquema.
//   No Teorema CAP este contexto e AP: o catalogo pode mostrar um dado com
//   alguns segundos de atraso sem prejuizo real.
// ============================================================================

db = db.getSiblingDB("erp_estoque");

// Limpeza para permitir reexecucao
db.produtos.drop();

// ----------------------------------------------------------------------------
// INSERCAO: documentos com ATRIBUTOS VARIAVEIS
// Repare que os tres produtos abaixo nao compartilham a mesma estrutura
// dentro de "especificacoes" -- e isso e valido e desejado.
// ----------------------------------------------------------------------------
db.produtos.insertMany([

  // ---------- ELETRONICO: muitos atributos tecnicos ----------
  {
    sku: "CEL-SMX-256",
    nome: "Smartphone Galaxy SMX 256GB",
    categoria: "eletronicos",
    preco: 3499.90,
    estoque: {
      quantidade: 42,
      reservado: 3,
      deposito: "CD-SAO-PAULO",
      estoque_minimo: 10
    },
    especificacoes: {
      tela: { tamanho_polegadas: 6.7, tecnologia: "AMOLED", taxa_atualizacao_hz: 120 },
      bateria_mah: 5000,
      memoria_ram_gb: 12,
      armazenamento_gb: 256,
      camera: { principal_mp: 200, frontal_mp: 12, zoom_optico: "3x" },
      chipset: "Snapdragon 8 Gen 4",
      sistema_operacional: "Android 16",
      conectividade: ["5G", "Wi-Fi 7", "Bluetooth 5.4", "NFC"],
      resistencia_agua: "IP68",
      peso_g: 221
    },
    dimensoes_embalagem: { altura_cm: 18, largura_cm: 9, profundidade_cm: 4 },
    garantia_meses: 12,
    atualizado_em: new Date()
  },

  // ---------- VESTUARIO: atributos COMPLETAMENTE diferentes ----------
  {
    sku: "CAM-BAS-PRT",
    nome: "Camiseta Basica Algodao Pima",
    categoria: "vestuario",
    preco: 89.90,
    estoque: {
      quantidade: 310,
      reservado: 18,
      deposito: "CD-FORTALEZA",
      estoque_minimo: 50
    },
    especificacoes: {
      cor: "Preto",
      tamanhos_disponiveis: ["P", "M", "G", "GG"],
      composicao: "100% algodao Pima",
      gramatura_g_m2: 180,
      modelagem: "regular",
      instrucoes_lavagem: "Lavar a maquina em agua fria, nao usar alvejante"
    },
    // Note: nao existe "garantia_meses" aqui, nem "dimensoes_embalagem".
    // Em um banco relacional essas colunas ficariam NULL para sempre.
    atualizado_em: new Date()
  },

  // ---------- ACESSORIO: estrutura minima, so 2 atributos ----------
  {
    sku: "CAB-HDMI-2M",
    nome: "Cabo HDMI 2.1 - 2 metros",
    categoria: "acessorios",
    preco: 49.90,
    estoque: {
      quantidade: 7,              // abaixo do minimo -> dispara alerta de reposicao
      reservado: 0,
      deposito: "CD-SAO-PAULO",
      estoque_minimo: 25
    },
    especificacoes: {
      comprimento_m: 2,
      versao: "2.1"
    },
    atualizado_em: new Date()
  }
]);

print(">>> Produtos inseridos: " + db.produtos.countDocuments());

// Indices para os padroes de acesso reais do contexto
db.produtos.createIndex({ sku: 1 }, { unique: true });
db.produtos.createIndex({ categoria: 1 });
db.produtos.createIndex({ "estoque.deposito": 1 });
// Indice em campo que existe em apenas PARTE dos documentos (indice esparso):
db.produtos.createIndex({ "especificacoes.memoria_ram_gb": 1 }, { sparse: true });

// ============================================================================
// CONSULTAS
// ============================================================================

print("\n--- 1) Catalogo completo (formatos diferentes convivendo) ---");
db.produtos.find({}, { sku: 1, nome: 1, categoria: 1, _id: 0 }).forEach(printjson);

print("\n--- 2) Consulta em campo que SO EXISTE em eletronicos ---");
// Nenhum JOIN, nenhuma tabela extra: o filtro atravessa o documento aninhado.
db.produtos.find(
  { "especificacoes.memoria_ram_gb": { $gte: 8 } },
  { sku: 1, nome: 1, "especificacoes.memoria_ram_gb": 1, _id: 0 }
).forEach(printjson);

print("\n--- 3) Produtos que precisam de reposicao ($expr comparando campos) ---");
db.produtos.find(
  { $expr: { $lt: ["$estoque.quantidade", "$estoque.estoque_minimo"] } },
  { sku: 1, nome: 1, "estoque.quantidade": 1, "estoque.estoque_minimo": 1, _id: 0 }
).forEach(printjson);

print("\n--- 4) Valor total imobilizado em estoque, por categoria (aggregation) ---");
db.produtos.aggregate([
  {
    $project: {
      categoria: 1,
      disponivel: { $subtract: ["$estoque.quantidade", "$estoque.reservado"] },
      valor_imobilizado: { $multiply: ["$preco", "$estoque.quantidade"] }
    }
  },
  {
    $group: {
      _id: "$categoria",
      itens: { $sum: 1 },
      unidades_disponiveis: { $sum: "$disponivel" },
      valor_imobilizado: { $sum: "$valor_imobilizado" }
    }
  },
  { $sort: { valor_imobilizado: -1 } }
]).forEach(printjson);

// ============================================================================
// BAIXA DE ESTOQUE
// Operacao disparada pelo evento "venda.finalizada" vindo do contexto de Vendas.
// $inc em um unico documento e atomico no MongoDB, e o filtro garante que a
// baixa so acontece se ainda houver saldo (evita estoque negativo).
// ============================================================================

print("\n--- 5) Baixa de 2 unidades do smartphone (evento venda.finalizada) ---");
const baixa = db.produtos.updateOne(
  { sku: "CEL-SMX-256", "estoque.quantidade": { $gte: 2 } },
  {
    $inc: { "estoque.quantidade": -2 },
    $set: { atualizado_em: new Date() },
    $push: {
      movimentacoes: {
        tipo: "SAIDA_VENDA",
        quantidade: 2,
        pedido: "PED-2026-0003",
        data: new Date()
      }
    }
  }
);
print("Documentos alterados: " + baixa.modifiedCount);

printjson(
  db.produtos.findOne(
    { sku: "CEL-SMX-256" },
    { sku: 1, "estoque.quantidade": 1, movimentacoes: 1, _id: 0 }
  )
);

print("\n--- 6) Tentativa de baixa maior que o saldo (deve falhar sem erro) ---");
const falha = db.produtos.updateOne(
  { sku: "CAB-HDMI-2M", "estoque.quantidade": { $gte: 100 } },
  { $inc: { "estoque.quantidade": -100 } }
);
print("Documentos alterados: " + falha.modifiedCount + " (0 = baixa recusada, estoque preservado)");
