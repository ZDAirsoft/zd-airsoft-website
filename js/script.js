// Add interactivity here if needed
console.log("Z&D Airsoft loaded successfully!");

let currentIndex = 0;
const slides = document.querySelectorAll('.carousel-slide');

function showSlide(index) {
  slides.forEach((slide, i) => {
    slide.style.display = i === index ? 'block' : 'none';
  });
}

function nextSlide() {
  currentIndex = (currentIndex + 1) % slides.length;
  showSlide(currentIndex);
}

// Auto-play
setInterval(nextSlide, 3000);
showSlide(currentIndex);

