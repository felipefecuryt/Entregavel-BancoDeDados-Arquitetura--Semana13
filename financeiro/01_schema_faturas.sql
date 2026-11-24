-- ============================================================================
-- CONTEXTO DELIMITADO: FINANCEIRO
-- SGBD: PostgreSQL (Relacional)
-- Arquivo: 01_schema_faturas.sql
--
-- Justificativa da escolha:
--   O Financeiro e o contexto onde o dado vale dinheiro. Toda operacao precisa
--   de garantias ACID: ou a fatura e emitida por inteiro, ou nada acontece.
--   O esquema aqui e rigido de proposito -- uma fatura sem valor, sem cliente
--   ou com status invalido nao pode nem existir no banco. Por isso usamos
--   constraints (NOT NULL, CHECK, FOREIGN KEY) como linha de defesa.
--   No Teorema CAP, este contexto e CP: prefere ficar indisponivel a devolver
--   um saldo errado.
-- ============================================================================

-- Limpeza para permitir reexecucao do script
DROP TABLE IF EXISTS pagamentos CASCADE;
DROP TABLE IF EXISTS faturas CASCADE;
DROP TABLE IF EXISTS clientes CASCADE;

-- ----------------------------------------------------------------------------
-- Entidade: Cliente
-- Guarda o saldo/limite de credito usado na transacao do desafio (Parte 3).
-- ----------------------------------------------------------------------------
CREATE TABLE clientes (
    id              SERIAL          PRIMARY KEY,
    nome            VARCHAR(120)    NOT NULL,
    cpf_cnpj        VARCHAR(18)     NOT NULL UNIQUE,
    saldo           NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    criado_em       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Regra de negocio no banco: saldo nunca pode ficar negativo.
    CONSTRAINT chk_saldo_nao_negativo CHECK (saldo >= 0)
);

-- ----------------------------------------------------------------------------
-- Entidade principal do contexto: Fatura
-- ----------------------------------------------------------------------------
CREATE TABLE faturas (
    id              SERIAL          PRIMARY KEY,
    cliente_id      INTEGER         NOT NULL,
    numero_pedido   VARCHAR(40)     NOT NULL UNIQUE,  -- referencia ao contexto de Vendas
    valor_total     NUMERIC(12,2)   NOT NULL,
    status          VARCHAR(20)     NOT NULL DEFAULT 'PENDENTE',
    data_emissao    DATE            NOT NULL DEFAULT CURRENT_DATE,
    data_vencimento DATE            NOT NULL,

    CONSTRAINT fk_fatura_cliente
        FOREIGN KEY (cliente_id) REFERENCES clientes (id),

    CONSTRAINT chk_valor_positivo
        CHECK (valor_total > 0),

    CONSTRAINT chk_status_valido
        CHECK (status IN ('PENDENTE', 'PAGA', 'CANCELADA', 'VENCIDA')),

    CONSTRAINT chk_vencimento_coerente
        CHECK (data_vencimento >= data_emissao)
);

-- ----------------------------------------------------------------------------
-- Entidade: Pagamento (um para muitos com fatura - pagamento parcelado)
-- ----------------------------------------------------------------------------
CREATE TABLE pagamentos (
    id              SERIAL          PRIMARY KEY,
    fatura_id       INTEGER         NOT NULL,
    valor_pago      NUMERIC(12,2)   NOT NULL,
    metodo          VARCHAR(30)     NOT NULL,
    pago_em         TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_pagamento_fatura
        FOREIGN KEY (fatura_id) REFERENCES faturas (id) ON DELETE CASCADE,

    CONSTRAINT chk_valor_pago_positivo CHECK (valor_pago > 0)
);

-- Indices para os acessos mais frequentes do contexto
CREATE INDEX idx_faturas_cliente  ON faturas (cliente_id);
CREATE INDEX idx_faturas_status   ON faturas (status);
CREATE INDEX idx_faturas_emissao  ON faturas (data_emissao);

-- ----------------------------------------------------------------------------
-- CARGA DE DADOS
-- A insercao vai dentro de uma transacao explicita: cliente e fatura entram
-- juntos ou nao entram. Esse e justamente o ganho do relacional aqui.
-- ----------------------------------------------------------------------------
BEGIN;

INSERT INTO clientes (nome, cpf_cnpj, saldo) VALUES
    ('Mercado Sao Jorge LTDA', '12.345.678/0001-90', 15000.00),
    ('Ana Beatriz Ferreira',   '987.654.321-00',      320.50);

-- Os 2 registros de fatura exigidos pelo enunciado
INSERT INTO faturas (cliente_id, numero_pedido, valor_total, status, data_emissao, data_vencimento) VALUES
    (1, 'PED-2026-0001', 4890.75, 'PAGA',     '2026-11-03', '2026-12-03'),
    (2, 'PED-2026-0002', 1259.90, 'PENDENTE', '2026-11-18', '2026-12-18');

INSERT INTO pagamentos (fatura_id, valor_pago, metodo) VALUES
    (1, 4890.75, 'PIX');

COMMIT;
