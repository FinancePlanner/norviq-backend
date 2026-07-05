#!/usr/bin/env bash
# Creates the two Hermes agent cron jobs that feed the finance pipeline using
# the agent's own SuperGrok OAuth (no xAI API key required).
#
# Run this ON THE VPS (or via: ssh root@78.46.192.73 'bash -s' < setup-hermes-agent-jobs.sh)
#
# Jobs:
#   hermes-ticker-sentiment  every 45m  → X posts per tracked symbol → ticker_posts
#   hermes-topic-sentiment   daily 06:00 UTC → topic pulse → fin_event
#
# Both jobs end by running ticker_sentiment_scraper.py --mode ingest-file,
# which validates, dedupes, and inserts the agent's JSON.
set -euo pipefail

PIPELINE=/root/.hermes/financial-pipeline
mkdir -p "${PIPELINE}/inbox"

hermes cron create "every 45m" --name hermes-ticker-sentiment --deliver local \
"Read the JSON config ${PIPELINE}/scraper_config.json. For EACH symbol in its tickers array: search X for substantive posts from the last 7 days about \$SYMBOL (the stock) that contain an actual investment thesis, analysis, or strong opinion from credible accounts. Exclude giveaways, bots, engagement bait, price-screenshot-only posts, and spam. Collect at most 10 posts per symbol; verbatim text max 500 chars. Write ONE file ${PIPELINE}/inbox/tickers-TIMESTAMP.json (TIMESTAMP = current unix seconds) with exactly this shape: {\"tickers\":[{\"symbol\":\"AMD\",\"author\":\"display name\",\"author_handle\":\"handle without @\",\"url\":\"https://x.com/HANDLE/status/ID\",\"text\":\"verbatim post text\",\"sentiment\":\"bullish|bearish|neutral\",\"sentiment_score\":0.0,\"confidence\":0.0,\"posted_at\":\"ISO 8601\"}]}. Every post object MUST include its symbol field. sentiment_score is in [-1,1], confidence in [0,1]. Only include posts you actually found via X search with real status URLs — never invent posts or URLs. If nothing substantive found for a symbol, include no posts for it. Then run in terminal: python3 ${PIPELINE}/scripts/ticker_sentiment_scraper.py --mode ingest-file --file THE_FILE_YOU_WROTE and report only the final ingest-file done log line."

hermes cron create "0 6 * * *" --name hermes-topic-sentiment --deliver local \
"Search X and recent news for the most substantive recent posts/articles (last 7 days, personal-finance angle) for EACH of these topics: Housing (housing market, mortgage rates, rent prices), Savings (savings rates, HYSA, emergency funds), Insurance (premiums and coverage trends), Retirement (401k, IRA, pensions, social security), NetWorth (wealth tracking, FIRE), Taxes (income tax, deductions, planning changes), Debt (credit cards, loans, rates, payoff), Crypto (BTC/ETH market moves, regulation), Stocks (market outlook, earnings), Expenses (cost of living, inflation, budgets). At most 10 items per topic. Write ONE file ${PIPELINE}/inbox/topics-TIMESTAMP.json (TIMESTAMP = current unix seconds) with exactly this shape: {\"topics\":[{\"topic\":\"Housing\",\"title\":\"short headline\",\"summary\":\"1-2 sentence factual summary\",\"url\":\"source link\",\"author\":\"author or outlet\",\"sentiment\":\"positive|neutral|negative\",\"sentiment_score\":0.0,\"published_at\":\"ISO 8601\"}]}. Every item MUST include its topic field, spelled exactly as listed above. sentiment reflects the tone for a person's finances; sentiment_score in [-1,1]. Only include items you actually found via search with real URLs — never invent items. Then run in terminal: python3 ${PIPELINE}/scripts/ticker_sentiment_scraper.py --mode ingest-file --file THE_FILE_YOU_WROTE and report only the final ingest-file done log line."

echo
hermes cron list 2>/dev/null | grep -iE "ticker-sentiment|topic-sentiment" || true
cat <<'NEXT'

Created. Kick off first runs immediately with:
  hermes cron run hermes-ticker-sentiment
  hermes cron run hermes-topic-sentiment
Then check:
  python3 -c "import sqlite3; c=sqlite3.connect('/root/.hermes/financial-pipeline/data/finance.sqlite'); print('ticker_posts:', c.execute('SELECT COUNT(*) FROM ticker_posts').fetchone()[0]); print('xai fin_event:', c.execute(\"SELECT COUNT(*) FROM fin_event WHERE source='xai_live_search'\").fetchone()[0])"
After the topic run has real rows, purge the junk:
  python3 /root/.hermes/financial-pipeline/scripts/ticker_sentiment_scraper.py --purge-source manual --yes
NEXT
