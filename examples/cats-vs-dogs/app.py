from flask import Flask, request, redirect, url_for
import sqlite3
import os

app = Flask(__name__)
DB_PATH = os.environ.get("DB_PATH", "/data/votes.db")


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS votes ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  choice TEXT NOT NULL"
        ")"
    )
    conn.commit()
    return conn


@app.route("/", methods=["GET"])
def index():
    db = get_db()
    cats = db.execute("SELECT COUNT(*) FROM votes WHERE choice='cats'").fetchone()[0]
    dogs = db.execute("SELECT COUNT(*) FROM votes WHERE choice='dogs'").fetchone()[0]
    db.close()
    total = cats + dogs
    cat_pct = round(cats / total * 100) if total else 50
    dog_pct = 100 - cat_pct if total else 50
    return render(cats, dogs, cat_pct, dog_pct, total)


@app.route("/vote", methods=["POST"])
def vote():
    choice = request.form.get("choice")
    if choice in ("cats", "dogs"):
        db = get_db()
        db.execute("INSERT INTO votes (choice) VALUES (?)", (choice,))
        db.commit()
        db.close()
    return redirect(url_for("index"))


@app.route("/reset", methods=["POST"])
def reset():
    db = get_db()
    db.execute("DELETE FROM votes")
    db.commit()
    db.close()
    return redirect(url_for("index"))


def render(cats, dogs, cat_pct, dog_pct, total):
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Cats vs Dogs — scale-to-zero-aws-ec2</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-900 min-h-screen flex items-center justify-center">
  <div class="max-w-lg w-full mx-auto px-4">
    <h1 class="text-4xl font-bold text-white text-center mb-2">🐱 vs 🐶</h1>
    <p class="text-gray-400 text-center mb-8">Cast your vote. Results persist even when this server sleeps.</p>

    <div class="flex gap-4 mb-8">
      <form method="POST" action="/vote" class="flex-1">
        <input type="hidden" name="choice" value="cats">
        <button type="submit"
          class="w-full bg-purple-600 hover:bg-purple-700 text-white text-xl font-bold py-8 rounded-xl transition transform hover:scale-105">
          🐱 Cats
        </button>
      </form>
      <form method="POST" action="/vote" class="flex-1">
        <input type="hidden" name="choice" value="dogs">
        <button type="submit"
          class="w-full bg-orange-500 hover:bg-orange-600 text-white text-xl font-bold py-8 rounded-xl transition transform hover:scale-105">
          🐶 Dogs
        </button>
      </form>
    </div>

    <div class="bg-gray-800 rounded-xl p-6">
      <div class="flex justify-between text-sm text-gray-400 mb-2">
        <span>🐱 {cats} votes ({cat_pct}%)</span>
        <span>🐶 {dogs} votes ({dog_pct}%)</span>
      </div>
      <div class="w-full bg-gray-700 rounded-full h-4 overflow-hidden">
        <div class="h-full flex">
          <div class="bg-purple-500 transition-all duration-500" style="width: {cat_pct}%"></div>
          <div class="bg-orange-400 transition-all duration-500" style="width: {dog_pct}%"></div>
        </div>
      </div>
      <p class="text-center text-gray-500 text-xs mt-3">{total} total votes</p>
      <form method="POST" action="/reset" class="mt-4 text-center">
        <button type="submit" class="text-xs text-gray-500 hover:text-red-400 transition">Reset votes</button>
      </form>
    </div>

    <footer class="mt-8 text-center text-xs text-gray-600">
      Powered by <a href="https://github.com/axilleasdev/scale-to-zero-aws-ec2" class="underline hover:text-gray-400">scale-to-zero-aws-ec2</a>
    </footer>
  </div>
</body>
</html>"""
