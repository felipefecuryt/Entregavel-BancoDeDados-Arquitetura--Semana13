-- ============================================================================
-- CONTEXTO FINANCEIRO - CONSULTAS
-- SGBD: PostgreSQL
-- Arquivo: 02_consultas.sql
-- Pre-requisito: executar 01_schema_faturas.sql antes.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) CONSULTA OBRIGATORIA: total faturado (SUM do valor_total)
-- ----------------------------------------------------------------------------
SELECT
    COUNT(*)            AS qtd_faturas,
    SUM(valor_total)    AS total_faturado
FROM faturas;

-- Resultado esperado: 2 faturas | 6150.65


-- ----------------------------------------------------------------------------
-- 2) Total faturado agrupado por status
--    Mostra quanto do faturamento ja entrou no caixa e quanto ainda e promessa.
-- ----------------------------------------------------------------------------
SELECT
    status,
    COUNT(*)                            AS qtd_faturas,
    SUM(valor_total)                    AS total_por_status,
    ROUND(AVG(valor_total), 2)          AS ticket_medio
FROM faturas
GROUP BY status
ORDER BY total_por_status DESC;


-- ----------------------------------------------------------------------------
-- 3) Faturamento por cliente (JOIN)
--    Aqui fica visivel a vantagem do relacional: o JOIN e nativo e barato
--    porque o esquema e estavel e as chaves sao conhecidas.
-- ----------------------------------------------------------------------------
SELECT
    c.nome                                      AS cliente,
    c.cpf_cnpj,
    COUNT(f.id)                                 AS qtd_faturas,
    SUM(f.valor_total)                          AS total_faturado,
    SUM(CASE WHEN f.status = 'PENDENTE'
             THEN f.valor_total ELSE 0 END)     AS em_aberto
FROM clientes c
LEFT JOIN faturas f ON f.cliente_id = c.id
GROUP BY c.id, c.nome, c.cpf_cnpj
ORDER BY total_faturado DESC NULLS LAST;


-- ----------------------------------------------------------------------------
-- 4) Faturamento mensal (serie temporal para o fechamento contabil)
-- ----------------------------------------------------------------------------
SELECT
    TO_CHAR(data_emissao, 'YYYY-MM')    AS competencia,
    SUM(valor_total)                    AS total_faturado
FROM faturas
GROUP BY TO_CHAR(data_emissao, 'YYYY-MM')
ORDER BY competencia;


-- ----------------------------------------------------------------------------
-- 5) Conciliacao: fatura x pagamentos recebidos
--    Detecta divergencia entre o que foi faturado e o que foi efetivamente pago.
-- ----------------------------------------------------------------------------
SELECT
    f.numero_pedido,
    f.valor_total,
    COALESCE(SUM(p.valor_pago), 0)                      AS total_recebido,
    f.valor_total - COALESCE(SUM(p.valor_pago), 0)       AS saldo_devedor,
    f.status
FROM faturas f
LEFT JOIN pagamentos p ON p.fatura_id = f.id
GROUP BY f.id, f.numero_pedido, f.valor_total, f.status
ORDER BY saldo_devedor DESC;
