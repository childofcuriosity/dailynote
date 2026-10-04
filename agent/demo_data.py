"""Synthetic public examples; never copy anything from the personal account."""
from pathlib import Path
from account_context import set_account, soul_path
from database import (
    init_db, get_db, create_conversation, insert_message, update_conversation,
    insert_memory, set_conversation_tags,
)


def seed_demo():
    set_account('demo')
    init_db()
    db = get_db()
    db.execute('CREATE TABLE IF NOT EXISTS demo_seed (version INTEGER PRIMARY KEY)')
    if db.execute('SELECT 1 FROM demo_seed WHERE version = 1').fetchone():
        return
    examples = [
        ('A weekend walk and small discoveries', 'I went for a walk in the park today. Slowing down helped me notice the little things.',
         'Try capturing three moments: what you saw, how you felt, and one thought to carry into tomorrow.',
         'A weekend walk at a slower pace.', ['Life', 'Mood']),
        ('A learning plan: twenty minutes a day', 'I want to learn Python, but I only have twenty minutes a day.',
         'Start with one small task: print a sentence today, then read and write a text file tomorrow. Leave one day each week for review.',
         'Building a learning habit with twenty minutes a day.', ['Learning']),
        ('A note to my future self', 'Life has been busy lately. I hope I remember to rest.',
         'A reminder: leave room for rest, even when you are busy. Do one small thing to relax tonight.',
         'Making room for rest during a busy week.', ['Life']),
    ]
    for title, question, reply, summary, tags in examples:
        conv = create_conversation(title=title)
        insert_message(conv['id'], 'user', question)
        insert_message(conv['id'], 'assistant', reply)
        update_conversation(conv['id'], summary=summary)
        set_conversation_tags(conv['id'], tags)
    insert_memory('The example user prefers learning tasks that take twenty minutes per day.',
                  name='demo-small-steps', description='Break learning advice into small steps', mem_type='feedback')
    insert_memory('The example user enjoys walks and recording small discoveries in a diary.',
                  name='demo-walking', description='Enjoys walking and journaling', mem_type='fact')
    Path(soul_path()).write_text('You are the public DailyNote demo assistant. The seeded diary entries and memories are fictional examples. Respond warmly and concisely in English. Write all titles, summaries, memories, and discoveries in English.', encoding='utf-8')
    db.execute('INSERT INTO demo_seed VALUES (1)')
    db.commit()
