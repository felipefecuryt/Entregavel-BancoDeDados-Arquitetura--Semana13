-- ============================================================================
-- CONTEXTO FINANCEIRO - BONUS (Parte 3)
-- SGBD: PostgreSQL
-- Arquivo: 03_transacao_saldo_rollback.sql
--
-- Objetivo: provar o poder do ACID. A transacao debita o saldo do cliente e
-- registra a fatura. Se o saldo for insuficiente, NADA e gravado -- nem o
-- debito parcial, nem a fatura. O banco volta exatamente ao estado anterior.
--
-- Pre-requisito: executar 01_schema_faturas.sql antes.
-- ============================================================================

-- Estado inicial dos saldos (anote estes valores para comparar depois)
SELECT id, nome, saldo FROM clientes ORDER BY id;
-- 1 | Mercado Sao Jorge LTDA | 15000.00
-- 2 | Ana Beatriz Ferreira   |   320.50


-- ############################################################################
-- CENARIO A - TRANSACAO QUE DA COMMIT (saldo suficiente)
-- Cliente 1 tem 15000.00 e a compra e de 2500.00 -> passa.
-- ############################################################################

BEGIN;

    -- 1. Debita o saldo. O CHECK (saldo >= 0) protege contra saldo negativo.
    UPDATE clientes
       SET saldo = saldo - 2500.00
     WHERE id = 1;

    -- 2. Emite a fatura correspondente
    INSERT INTO faturas (cliente_id, numero_pedido, valor_total, status, data_vencimento)
    VALUES (1, 'PED-2026-0003', 2500.00, 'PAGA', CURRENT_DATE + INTERVAL '30 days');

    -- 3. Registra o pagamento
    INSERT INTO pagamentos (fatura_id, valor_pago, metodo)
    VALUES ((SELECT id FROM faturas WHERE numero_pedido = 'PED-2026-0003'), 2500.00, 'SALDO_EM_CONTA');

COMMIT;
-- Saldo do cliente 1 agora: 12500.00  (as 3 operacoes foram gravadas juntas)


-- ############################################################################
-- CENARIO B - TRANSACAO QUE FALHA E DA ROLLBACK (saldo insuficiente)
-- Cliente 2 tem 320.50 e tenta uma compra de 1800.00 -> deve falhar.
--
-- O bloco DO captura a excecao gerada pela constraint. A mensagem explica o
-- motivo e o ROLLBACK e automatico: nem o UPDATE nem o INSERT persistem.
-- ############################################################################

DO $$
DECLARE
    v_cliente_id    INTEGER := 2;
    v_valor_compra  NUMERIC(12,2) := 1800.00;
    v_saldo_atual   NUMERIC(12,2);
BEGIN
    -- FOR UPDATE bloqueia a linha para evitar que duas compras simultaneas
    -- leiam o mesmo saldo e gastem o dinheiro duas vezes (race condition).
    SELECT saldo INTO v_saldo_atual
      FROM clientes
     WHERE id = v_cliente_id
       FOR UPDATE;

    IF v_saldo_atual < v_valor_compra THEN
        RAISE EXCEPTION
            'SALDO INSUFICIENTE: cliente % possui R$ % e tentou debitar R$ %. Transacao desfeita.',
            v_cliente_id, v_saldo_atual, v_valor_compra;
    END IF;

    UPDATE clientes
       SET saldo = saldo - v_valor_compra
     WHERE id = v_cliente_id;

    INSERT INTO faturas (cliente_id, numero_pedido, valor_total, status, data_vencimento)
    VALUES (v_cliente_id, 'PED-2026-0004', v_valor_compra, 'PAGA', CURRENT_DATE + INTERVAL '30 days');

    RAISE NOTICE 'Transacao concluida com sucesso.';

EXCEPTION
    WHEN OTHERS THEN
        -- Todo o trabalho do bloco e descartado automaticamente (ROLLBACK).
        RAISE NOTICE 'TRANSACAO ABORTADA -> %', SQLERRM;
END $$;


-- ############################################################################
-- CENARIO C - ROLLBACK EXPLICITO (versao manual, sem PL/pgSQL)
-- Mesmo que o UPDATE passe, o ROLLBACK desfaz tudo.
-- ############################################################################

BEGIN;

    UPDATE clientes SET saldo = saldo - 300.00 WHERE id = 2;

    -- Verificacao: se o saldo ficasse negativo, o CHECK dispararia erro aqui.
    SELECT id, nome, saldo AS saldo_dentro_da_transacao
      FROM clientes WHERE id = 2;

ROLLBACK;  -- desfaz o debito de 300.00


-- ############################################################################
-- VERIFICACAO FINAL
-- ############################################################################
SELECT id, nome, saldo FROM clientes ORDER BY id;
-- 1 | Mercado Sao Jorge LTDA | 12500.00  <- alterado pelo COMMIT do cenario A
-- 2 | Ana Beatriz Ferreira   |   320.50  <- INTACTO (cenarios B e C sofreram rollback)

SELECT numero_pedido, valor_total, status FROM faturas ORDER BY id;
-- PED-2026-0001, PED-2026-0002, PED-2026-0003
-- PED-2026-0004 NAO existe: a transacao que falhou nao deixou rastro.
