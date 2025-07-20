defmodule Example.Repo.Migrations.AddSectionStats do
  use Ecto.Migration

  def up do
    execute """
    CREATE TEXT SEARCH DICTIONARY english_stem (TEMPLATE = snowball, LANGUAGE = english);
    """

    execute """
    CREATE TEXT SEARCH DICTIONARY simple_dict (TEMPLATE = pg_catalog.simple, STOPWORDS = english);
    """

    execute """
    CREATE TEXT SEARCH CONFIGURATION simple_conf (PARSER = 'default');
    """

    execute """
    ALTER TEXT SEARCH CONFIGURATION simple_conf
    ALTER MAPPING FOR asciiword, word, numword, asciihword, hword, numhword
    WITH english_stem, simple_dict;
    """

    execute """
    CREATE OR REPLACE FUNCTION tokenize_and_count(input_text TEXT)
    RETURNS TABLE (term TEXT, count INTEGER) AS $$
    BEGIN
        -- Get stemmed tokens with stop words removed
        RETURN QUERY
        WITH tokens AS (
            SELECT word
            FROM ts_parse('default', lower(input_text)) AS t(tokid, word)
            WHERE tokid != 12
        ),
        processed_tokens AS (
            SELECT
                CASE
                    WHEN ts_lexize('public.simple_dict', word) = '{}'  -- It's a stop word
                    THEN NULL
                    ELSE COALESCE(
                        (ts_lexize('public.english_stem', word))[1],  -- Try stemming
                        word                                          -- Keep original if can't stem
                    )
                END AS processed_word
            FROM tokens
        )
        SELECT
            processed_word as term,
            COUNT(*)::INTEGER
        FROM processed_tokens
        WHERE processed_word IS NOT NULL
        GROUP BY processed_word;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE OR REPLACE FUNCTION calculate_idf(term_doc_count INTEGER, total_docs INTEGER)
    RETURNS FLOAT AS $$
    BEGIN
        -- Modified BM25 IDF formula to ensure non-negative scores
        RETURN ln(1 + (total_docs - term_doc_count + 0.5) /
                      (term_doc_count + 0.5));
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE OR REPLACE FUNCTION bm25_term_score(
        tf INTEGER,           -- term frequency in document
        doc_length INTEGER,   -- length of document
        idf FLOAT,            -- inverse document frequency
        avg_length FLOAT,     -- average document length
        k1 FLOAT DEFAULT 1.2,
        b FLOAT DEFAULT 0.75
    ) RETURNS FLOAT AS $$
    DECLARE
        numerator FLOAT;
        denominator FLOAT;
        normalized_length FLOAT;
    BEGIN
        IF tf IS NULL OR tf = 0 THEN
            RETURN 0.0;
        END IF;

        normalized_length := doc_length/avg_length;

        numerator := tf * (k1 + 1);
        denominator := tf + k1 * (1 - b + b * normalized_length);

        RETURN idf * (numerator / denominator);
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TABLE IF NOT EXISTS term_stats (
        term TEXT PRIMARY KEY,
        doc_count INTEGER NOT NULL,  -- n(qi)
        total_count INTEGER NOT NULL -- total occurrences
    );
    """

    execute """
    CREATE TABLE IF NOT EXISTS section_stats (
        section_id BIGINT PRIMARY KEY REFERENCES sections(id),
        length INTEGER NOT NULL,
        terms JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    """

    execute """
    CREATE OR REPLACE FUNCTION index_document(section_id BIGINT, section_text TEXT)
    RETURNS BIGINT AS $$
    DECLARE
        doc_length INTEGER;
        term_counts JSONB;
    BEGIN
        WITH term_counts_cte AS (
            SELECT * FROM tokenize_and_count(section_text)
        )
        SELECT
            json_object_agg(term, count)::jsonb,
            sum(count)
        INTO term_counts, doc_length
        FROM term_counts_cte;

        IF doc_length IS NULL THEN
            doc_length := 0;
            term_counts := '{}'::jsonb;
        END IF;

        INSERT INTO section_stats (section_id, length, terms)
        VALUES (section_id, doc_length, term_counts);

        INSERT INTO term_stats (term, doc_count, total_count)
        SELECT term, 1, (term_counts->term)::integer
        FROM jsonb_object_keys(term_counts) term
        ON CONFLICT (term) DO UPDATE SET
            doc_count = term_stats.doc_count + 1,
            total_count = term_stats.total_count + (EXCLUDED.total_count);

        RETURN section_id;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE OR REPLACE FUNCTION update_document_index(p_section_id BIGINT, new_section_text TEXT)
    RETURNS BIGINT AS $$
    DECLARE
        old_terms JSONB;
        new_doc_length INTEGER;
        new_term_counts JSONB;
    BEGIN
        SELECT terms INTO old_terms
        FROM section_stats
        WHERE section_id = p_section_id;

        -- If section doesn't exist, fall back to index_document function
        IF old_terms IS NULL THEN
            RETURN index_document(p_section_id, new_section_text);
        END IF;

        -- Calculate new term frequencies
        WITH term_counts_cte AS (
            SELECT * FROM tokenize_and_count(new_section_text)
        )
        SELECT
            json_object_agg(term, count)::jsonb,
            sum(count)
        INTO new_term_counts, new_doc_length
        FROM term_counts_cte;

        IF new_doc_length IS NULL THEN
            new_doc_length := 0;
            new_term_counts := '{}'::jsonb;
        END IF;

        UPDATE section_stats
        SET
            length = new_doc_length,
            terms = new_term_counts,
            created_at = NOW()
        WHERE section_id = p_section_id;

        WITH removed_terms AS (
            SELECT term, (old_terms->term)::integer as count
            FROM jsonb_object_keys(old_terms) term
            WHERE NOT new_term_counts ? term
        )
        UPDATE term_stats
        SET
            doc_count = CASE
                WHEN doc_count <= 1 THEN 0
                ELSE doc_count - 1
            END,
            total_count = total_count - removed_terms.count
        FROM removed_terms
        WHERE term_stats.term = removed_terms.term;

        -- For terms that were in both old and new document
        WITH updated_terms AS (
            SELECT
                term,
                (old_terms->term)::integer as old_count,
                (new_term_counts->term)::integer as new_count
            FROM jsonb_object_keys(old_terms) term
            WHERE new_term_counts ? term
        )
        UPDATE term_stats
        SET total_count = total_count - old_count + new_count
        FROM updated_terms
        WHERE term_stats.term = updated_terms.term;

        -- For terms that are only in new document
        INSERT INTO term_stats (term, doc_count, total_count)
        SELECT term, 1, (new_term_counts->term)::integer
        FROM jsonb_object_keys(new_term_counts) term
        WHERE NOT old_terms ? term
        ON CONFLICT (term) DO UPDATE SET
            doc_count = term_stats.doc_count + 1,
            total_count = term_stats.total_count + (EXCLUDED.total_count);

        DELETE FROM term_stats WHERE doc_count = 0;

        RETURN p_section_id;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE OR REPLACE FUNCTION search_sections(
        query_text TEXT,
        k1 FLOAT DEFAULT 1.2,
        b FLOAT DEFAULT 0.75,
        limit_val INTEGER DEFAULT 10,
        similarity_threshold FLOAT DEFAULT 0.3
    ) RETURNS TABLE (
        section_id BIGINT,
        score FLOAT,
        highlighted_content TEXT
    ) AS $$
    DECLARE
        v_total_docs INTEGER;
        v_avg_length FLOAT;
    BEGIN
        SELECT gs.total_docs, gs.avg_length
        INTO v_total_docs, v_avg_length
        FROM global_stats gs;

        RETURN QUERY
        WITH raw_query_terms AS (
            SELECT term
            FROM tokenize_and_count(query_text)
        ),
        query_terms AS (
            SELECT DISTINCT corrected_term AS term
            FROM raw_query_terms rqt
            CROSS JOIN LATERAL (
                SELECT ts.term AS corrected_term
                FROM term_stats ts
                WHERE similarity(rqt.term, ts.term) >= similarity_threshold
                ORDER BY similarity(rqt.term, ts.term) DESC
                LIMIT 1
            ) AS best_match
        ),
        search_query AS (
            SELECT to_tsquery('simple', string_agg(term, ' | ')) as q
            FROM query_terms
        ),
        term_scores AS (
            SELECT
                d.section_id,
                bm25_term_score(
                    (d.terms->>t.term)::INTEGER,
                    d.length,
                    calculate_idf(ts.doc_count, v_total_docs),
                    v_avg_length,
                    k1,
                    b
                ) AS term_score,
                sect.text AS doc_text
            FROM
                section_stats d
            JOIN
                sections sect ON sect.id = d.section_id
            JOIN
                query_terms t ON d.terms ? t.term
            JOIN
                term_stats ts ON ts.term = t.term
        )
        SELECT
            ts.section_id,
            SUM(ts.term_score) AS score,
            ts_headline(
                'public.simple_conf',
                ts.doc_text,
                (SELECT q FROM search_query),
                'StartSel=<mark>, StopSel=</mark>, MaxFragments=10, MinWords=5, MaxWords=10'
            ) AS highlighted_content
        FROM
            term_scores ts
        GROUP BY
            ts.section_id,
            ts.doc_text
        ORDER BY
            score DESC
        LIMIT limit_val;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE MATERIALIZED VIEW global_stats AS SELECT COUNT(*) as total_docs, AVG(length) as avg_length, 1 AS pkey FROM section_stats;
    """

    execute """
    CREATE UNIQUE INDEX idx_global_stats_pkey ON global_stats(pkey);
    """

    execute """
    CREATE INDEX idx_section_stats_terms ON section_stats USING gin(terms);
    """

    execute """
    CREATE OR REPLACE FUNCTION index_all_sections()
    RETURNS INTEGER AS $$
    DECLARE
        indexed_count INTEGER := 0;
    BEGIN
        SELECT COUNT(*) INTO indexed_count
        FROM (
            SELECT index_document(id, text)
            FROM sections
            ORDER BY id
        ) AS indexed_sections;

        REFRESH MATERIALIZED VIEW CONCURRENTLY global_stats;

        RETURN indexed_count;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE OR REPLACE FUNCTION update_modified_sections()
    RETURNS INTEGER AS $$
    DECLARE
        updated_count INTEGER := 0;
    BEGIN
        SELECT COUNT(*) INTO updated_count
        FROM (
            SELECT update_document_index(s.id, s.text)
            FROM sections s
            LEFT JOIN section_stats ss ON ss.section_id = s.id
            WHERE ss.created_at IS NULL
               OR s.updated_at > ss.created_at  -- Assumes you have updated_at column
            ORDER BY s.id
        ) AS updated_sections;

        REFRESH MATERIALIZED VIEW CONCURRENTLY global_stats;

        RETURN updated_count;
    END;
    $$ LANGUAGE plpgsql;
    """

    # trigram-based text search for typos
    execute """
    CREATE INDEX IF NOT EXISTS idx_term_stats_trgm ON term_stats USING gin (term gin_trgm_ops);
    """
  end

  def down do

  end
end
