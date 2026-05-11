"""
Telegram-бот для заказа чековой ленты и этикеток.
Требования: pip install python-telegram-bot==20.7
"""

import logging
import json
import os
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, filters, ContextTypes, ConversationHandler
)

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO
)
logger = logging.getLogger(__name__)

BOT_TOKEN = "8496814469:AAHJvjfQNIQInLYxXzeid6RAFqHfx9SGwYc"

ORDERS_FILE = "orders.json"

(
    STATE_CATEGORY,
    STATE_SIZE,
    STATE_QUANTITY,
    STATE_ADDRESS_CHOICE,
    STATE_ADDRESS_INPUT,
    STATE_CONFIRM,
) = range(6)

CATALOG = {
    "tape": {
        "name": "🧾 Чековая лента",
        "sizes": {
            "57x40": {"label": "57 мм × 40 м", "price": 85},
            "57x60": {"label": "57 мм × 60 м", "price": 110},
            "80x60": {"label": "80 мм × 60 м", "price": 140},
            "80x80": {"label": "80 мм × 80 м", "price": 170},
        },
    },
    "label": {
        "name": "🏷 Этикетка",
        "sizes": {
            "58x40": {"label": "58 × 40 мм (1000 шт/рул)", "price": 130},
            "58x60": {"label": "58 × 60 мм (700 шт/рул)", "price": 150},
            "75x120": {"label": "75 × 120 мм (500 шт/рул)", "price": 180},
            "100x150": {"label": "100 × 150 мм (350 шт/рул)", "price": 220},
        },
    },
}

def load_orders() -> dict:
    if os.path.exists(ORDERS_FILE):
        with open(ORDERS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def save_orders(orders: dict):
    with open(ORDERS_FILE, "w", encoding="utf-8") as f:
        json.dump(orders, f, ensure_ascii=False, indent=2)

def get_user_address(user_id: int):
    orders = load_orders()
    return orders.get(str(user_id), {}).get("last_address")

def save_order(user_id: int, order_data: dict):
    orders = load_orders()
    uid = str(user_id)
    if uid not in orders:
        orders[uid] = {}
    if "history" not in orders[uid]:
        orders[uid]["history"] = []
    order_data["created_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    orders[uid]["history"].append(order_data)
    orders[uid]["last_address"] = order_data["address"]
    save_orders(orders)

def format_order_summary(data: dict) -> str:
    cat = CATALOG[data["category"]]
    size = cat["sizes"][data["size"]]
    total = size["price"] * data["quantity"]
    return (
        f"📦 *Ваш заказ:*\n"
        f"• Товар: {cat['name']}\n"
        f"• Размер: {size['label']}\n"
        f"• Количество: {data['quantity']} рул.\n"
        f"• Цена за рулон: {size['price']} ₽\n"
        f"• *Итого: {total} ₽*\n\n"
        f"📍 *Адрес доставки:*\n{data['address']}"
    )

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    context.user_data.clear()
    keyboard = [
        [InlineKeyboardButton("🧾 Чековая лента", callback_data="cat_tape")],
        [InlineKeyboardButton("🏷 Этикетка", callback_data="cat_label")],
    ]
    await update.message.reply_text(
        "👋 Добро пожаловать!\n\nЯ помогу оформить заказ расходных материалов.\nВыберите категорию товара:",
        reply_markup=InlineKeyboardMarkup(keyboard),
    )
    return STATE_CATEGORY

async def choose_category(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    query = update.callback_query
    await query.answer()
    category = query.data.replace("cat_", "")
    context.user_data["category"] = category
    cat = CATALOG[category]
    keyboard = [
        [InlineKeyboardButton(info["label"], callback_data=f"size_{key}")]
        for key, info in cat["sizes"].items()
    ]
    keyboard.append([InlineKeyboardButton("◀️ Назад", callback_data="back_start")])
    await query.edit_message_text(
        f"{cat['name']}\n\nВыберите размер:",
        reply_markup=InlineKeyboardMarkup(keyboard),
    )
    return STATE_SIZE

async def choose_size(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    query = update.callback_query
    await query.answer()
    size = query.data.replace("size_", "")
    context.user_data["size"] = size
    cat = CATALOG[context.user_data["category"]]
    size_info = cat["sizes"][size]
    await query.edit_message_text(
        f"✅ Выбрано: *{cat['name']}* — {size_info['label']}\n"
        f"Цена: {size_info['price']} ₽/рул.\n\nВведите количество рулонов (от 1 до 9999):",
        parse_mode="Markdown",
    )
    return STATE_QUANTITY

async def enter_quantity(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    text = update.message.text.strip()
    if not text.isdigit() or not (1 <= int(text) <= 9999):
        await update.message.reply_text("⚠️ Пожалуйста, введите целое число от 1 до 9999.")
        return STATE_QUANTITY
    context.user_data["quantity"] = int(text)
    user_id = update.effective_user.id
    saved_address = get_user_address(user_id)
    if saved_address:
        keyboard = [
            [InlineKeyboardButton("✅ Использовать сохранённый адрес", callback_data="addr_use")],
            [InlineKeyboardButton("✏️ Ввести новый адрес", callback_data="addr_new")],
        ]
        await update.message.reply_text(
            f"📍 *Ваш сохранённый адрес:*\n`{saved_address}`\n\nИспользовать его или указать новый?",
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(keyboard),
        )
        return STATE_ADDRESS_CHOICE
    else:
        await update.message.reply_text(
            "📍 Введите адрес доставки:\n_(Город, улица, дом, кв./офис)_",
            parse_mode="Markdown",
        )
        return STATE_ADDRESS_INPUT

async def address_choice(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    query = update.callback_query
    await query.answer()
    if query.data == "addr_use":
        context.user_data["address"] = get_user_address(update.effective_user.id)
        return await show_confirmation(query, context)
    else:
        await query.edit_message_text(
            "📍 Введите новый адрес доставки:\n_(Город, улица, дом, кв./офис)_",
            parse_mode="Markdown",
        )
        return STATE_ADDRESS_INPUT

async def enter_address(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    address = update.message.text.strip()
    if len​​​​​​​​​​​​​​​​
